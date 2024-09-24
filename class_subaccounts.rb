class Api::V1::AuxiliarySubaccountsController < ApplicationController
  before_action :set_company
  before_action :set_auxiliary_subaccount, only: %i[ show update]
  
  def index
    @auxiliary_subaccounts = AuxiliarySubaccount.list(@company.id, params[:parent_id])
    render_success('', AuxiliarySubaccountSerializer.render_as_hash(@auxiliary_subaccounts, view: :index), 200)
  end

  def show
    render_success('', AuxiliarySubaccountSerializer.render_as_hash(@auxiliary_subaccount, view: :show), 200)
  end

  def update
    if @auxiliary_subaccount.update(auxiliary_subaccounts_params)
      render_success('', AuxiliarySubaccountSerializer.render_as_hash(@auxiliary_subaccount, view: :show), 200)
    else
      render_error(@auxiliary_subaccount.errors.full_messages.first, '', 422)
    end
  end

  def fetch_account
    account = CatAccount.find_by_id_or_code(params[:parent_id], params[:code])

    formated_json = if account
      {
        account_code: params[:parent_id] ? SubAccountService.calculate_account_code(@company.id, account) : nil,
        account_type: account.account_type.description,
        subaccount_of: SubAccountService.format_account_string(account)
      }
    else
      SubAccountService.empty_account_info
    end

    render_success('', formated_json, 200)
  end

  def create
    @auxiliary_subaccount = AuxiliarySubaccount.new(auxiliary_subaccounts_params)
    @auxiliary_subaccount.company_id = @company.id

    if @auxiliary_subaccount.save
      render_success('', AuxiliarySubaccountSerializer.render_as_hash(@auxiliary_subaccount), 201)
    else
      render_error(@auxiliary_subaccount.errors.full_messages.first, '', 422)
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_auxiliary_subaccount
      @auxiliary_subaccount = @company.auxiliary_subaccounts.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render_error('Subcuenta Auxiliar no encontrada', '', 404)
    end

    # Only allow a trusted parameter "white list" through.
    def auxiliary_subaccounts_params
      params.require(:auxiliary_subaccount).permit(:account_id, :code, :name, :currency)
    end
end
