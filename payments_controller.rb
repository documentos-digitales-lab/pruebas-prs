# Controller used by UCO / checkout for making payment request to BigPay. This controller is used for providers
# implemented in Payments SDK.
class PaymentsController < ApplicationController
  skip_before_action :verify_authenticity_token

  before_action :validate_jwt, only: [:create, :update, :show]
  before_action :perform_human_verification, if: :pay_with_card?, only: [:create]
  before_action :validate_request_payload, only: [:create]
  before_action :validate_profile, only: [:create]

  prepend_around_action :generate_metrics, if: :prometheus_enabled, only: [:create]

  attr_reader :pay_response

  def create
    @pay_response = PaymentsService.new.create_payment(payment_request)
    Rails.logger.info("Payment finished. Transaction_id: #{pay_response.transaction_id} and response status: #{pay_response.status}")

    increment_transaction_count(pay_response.status, pay_response.result) if pay_with_card?
    render status: :ok, json: map_response(pay_response), location: "/payments/#{pay_response.transaction_id}"

  rescue BigPay::ConfigurationError::ProfileNotFound => e
    Rails.logger.warn("Profile not found while performing payment request #{e.message}")

    render status: :bad_request, json: { type: 'error', code: 'payment_config_not_found' }
  end

  def show
    pay_response = PaymentsService.new.get_payment(jwt, payment_id)
    return error_404 if pay_response.nil?

    render status: :ok, json: map_response(pay_response)
  end

  def update; end

  private

  # @return [Payments::Request::PaymentRequest]
  def payment_request
    @payment_request ||= Payments::Request::PaymentRequest.new(
      payment_method_id: payment_method_id,
      auth_token: jwt,
      instrument: payment_instrument,
      remote_ip: request.remote_ip,
      human_verification: human_verification,
      request_id: request.uuid,
      profile_id: payment_profile.id
    )
  end

  def validate_profile
    payment_profile
  rescue BigPay::ConfigurationError::ProfileNotFound => e
    Rails.logger.warn("Profile not found while performing payment request #{e.message}")

    render status: :bad_request, json: { type: 'error', code: 'payment_config_not_found' }
  end

  def payment_profile
    @payment_profile ||= BigPay::ProfileService.new(
      store_id: store_id,
      provider_id: provider_id,
      currency: currency
    ).profile!
  end

  def provider_id
    @provider_id ||= payment_method_id.provider_id
  end

  def validate_request_payload
    errors = Payments::PaymentsRequestSchemaValidator.new(payment_request_params).validate.messages
    return if errors.blank?

    raise BigPay::Payments::PaymentsError::InvalidRequestError, errors.values.to_s
  end

  def validate_jwt
    return if BigPay::Payments::AuthTokenService.verified_token? jwt

    raise BigPay::Payments::PaymentsError::InvalidJwtError, 'The access token is invalid.'
  end

  # @return [Hash]
  def payment_request_params
    payment_request_params = {
      payment_method_id: params.fetch(:payment_method_id, '')
    }

    @payment_request_params ||= merge_optional_params(payment_request_params)
  end

  # @return [Hash]
  def merge_optional_params(payment_request_params)
    optional_param_keys = [:store, :instrument, :human_verification]
    optional_param_keys.each do |key|
      if params.key?(key)
        param = params.fetch(key).permit!.to_h
        payment_request_params.merge!({ key => param })
      end
    end

    payment_request_params
  end

  # @return [Integer]
  def payment_id
    @payment_id ||= params[:id]
  end

  # @return [Payment::Entities::Instrument]
  def payment_instrument
    Payments::Builders::InstrumentBuilder.build(payment_request_params)
  end

  # @return [Shared::Entities::PaymentMethodId]
  def payment_method_id
    @payment_method_id ||= Shared::Entities::PaymentMethodId.new(payment_request_params[:payment_method_id])
  end

  # @return [Payments::Request::HumanVerification, nil]
  def human_verification
    Payments::Builders::HumanVerificationBuilder.build(payment_request_params)
  end

  # @return [BigPay::FraudProtection::HumanVerification]
  def human_verification_service
    BigPay::FraudProtection::HumanVerification.new(store_id)
  end

  def store_id
    @store_id ||= jwt.payload[:store_id]
  end

  def currency
    @currency ||= jwt.payload[:currency]
  end

  def increment_transaction_count(response_status, result)
    return unless response_status == :complete

    tracking_service = BigPay::FraudProtection::Transactions::TrackingService.new(store_id)
    response_status = result.success? || result.continue? ? BigPay::Common::Constants::Payload::STATUS_OK : BigPay::Common::Constants::Payload::STATUS_ERROR
    tracking_service.increment_transaction_count(response_status, [result.code.to_s])
  end

  def pay_with_card?
    params.dig(:instrument, :type) == 'card'
  end

  def perform_human_verification
    human_verification_result = human_verification_service.verify(
      origin: jwt.payload(store_id)[:store_url] || request.origin,
      verification_params: human_verification
    )

    # HUMAN_VERIFICATION_SUCCESS means we don't need to halt the callback chain
    case human_verification_result
    when BigPay::Common::Constants::HumanVerification::Result::HUMAN_VERIFICATION_REQUIRED
      render status: :ok, json: Payments::PaymentsResponseMapper.resubmit_with_human_verification_response
    when BigPay::Common::Constants::HumanVerification::Result::HUMAN_VERIFICATION_FAILED
      render status: :ok, json: { type: 'failed', code: 'declined' }
    end
  end

  # @param payment_result [Payment::Commands::Pay::Response]
  # @return [Hash]
  def map_response(payment_result)
    Payments::PaymentsResponseMapper.new(payment_result).map_response
  end

  def error_404
    render status: :not_found, body: 'No payment matches the given ID.'
  end

  def generate_metrics
    start = Time.current
    yield
    timing = Time.current - start

    generate_payment_result_metric(timing)
  rescue StandardError => e
    Rails.logger.error "Error while performing payment request. Generating error metric for: #{e.message}", e
    generate_metric_due_to_payment_processing_error

    raise e
  end

  def generate_payment_result_metric(timing)
    BigPay::Common::Metric::Prometheus::PaymentsCollector.new.generate_payment_metrics(
      gateway_name: provider_id,
      status: status,
      error_code: pay_response.result.code,
      transaction_type: transaction_type,
      payment_method: payment_request.payment_method_id.method_id,
      vault: false,
      endpoint: 'payments_endpoint',
      timing: timing
    )
  rescue StandardError => e
    Rails.logger.warn "Informational only, not actually an issue affecting payment processing: could not generate metrics: #{e.message}", e
  end

  def generate_metric_due_to_payment_processing_error
    BigPay::Common::Metric::Prometheus::PaymentsCollector.new.generate_metric_due_to_payment_processing_error(
      gateway_name: provider_id,
      vault: false,
      endpoint: 'payments_endpoint'
      )
  rescue StandardError => e
    Rails.logger.warn "Informational only, not actually an issue affecting payment processing: could not generate payment_processing_error metrics: #{e.message}", e
  end

  def status
    [:success, :continue].include?(pay_response.result.type) ? BigPay::Common::Constants::Payload::STATUS_OK : BigPay::Common::Constants::Payload::STATUS_ERROR
  end

  def transaction_type
    result_code = pay_response.result.code
    Adapters::Bigpay::Builders::PayResponseBuilder::TRANSACTION_TYPE_TO_SUCCESS_CODE_MAP.invert.fetch(result_code, result_code)
  end

  def prometheus_enabled
    Settings.prometheus.enabled
  end
end
