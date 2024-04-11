# frozen_string_literal: true

module ShopifyApp
  module TokenExchange
    extend ActiveSupport::Concern
    include ShopifyApp::AdminAPI::WithTokenRefetch

    def activate_shopify_session(&block)
      retrieve_session_from_token_exchange if current_shopify_session.blank? || should_exchange_expired_token?

      begin
        ShopifyApp::Logger.debug("Activating Shopify session")
        ShopifyAPI::Context.activate_session(current_shopify_session)
        with_token_refetch(current_shopify_session, session_token, &block)
      rescue ShopifyAPI::Errors::HttpResponseError => error
        if error.code == 401
          ShopifyApp::Logger.debug("Admin API returned a 401 Unauthorized error, deleting current access token.")
          ShopifyApp::SessionRepository.delete_session(current_shopify_session_id)
        end
        raise
      ensure
        ShopifyApp::Logger.debug("Deactivating session")
        ShopifyAPI::Context.deactivate_session
      end
    end

    def should_exchange_expired_token?
      ShopifyApp.configuration.check_session_expiry_date && current_shopify_session.expired?
    end

    def current_shopify_session
      return unless current_shopify_session_id

      @current_shopify_session ||= ShopifyApp::SessionRepository.load_session(current_shopify_session_id)
    end

    def current_shopify_session_id
      @current_shopify_session_id ||= ShopifyAPI::Utils::SessionUtils.current_session_id(
        request.headers["HTTP_AUTHORIZATION"],
        nil,
        online_token_configured?,
      )
    end

    def current_shopify_domain
      return if params[:shop].blank?

      ShopifyApp::Utils.sanitize_shop_domain(params[:shop])
    end

    private

    def retrieve_session_from_token_exchange
      @current_shopify_session = nil
      # TODO: Right now JWT Middleware only updates env['jwt.shopify_domain'] from request headers tokens,
      # which won't work for new installs.
      # we need to update the middleware to also update the env['jwt.shopify_domain'] from the query params
      ShopifyApp::Auth::TokenExchange.perform(session_token)
      # TODO: Rescue JWT validation errors when bounce page is ready
      # rescue ShopifyAPI::Errors::InvalidJwtTokenError
      #   respond_to_invalid_session_token
    end

    def session_token
      @session_token ||= id_token_header
    end

    def id_token_header
      request.headers["HTTP_AUTHORIZATION"]&.match(/^Bearer (.+)$/)&.[](1)
    end

    def respond_to_invalid_session_token
      # TODO: Implement this method to handle invalid session tokens

      # if request.xhr?
      # response.set_header("X-Shopify-Retry-Invalid-Session-Request", 1)
      # unauthorized_response = { message: :unauthorized }
      # render(json: { errors: [unauthorized_response] }, status: :unauthorized)
      # else
      # patch_session_token_url = "#{ShopifyAPI::Context.host}/patch_session_token"
      # patch_session_token_params = request.query_parameters.except(:id_token)

      # bounce_url = "#{ShopifyAPI::Context.host}#{request.path}?#{patch_session_token_params.to_query}"

      # # App Bridge will trigger a fetch to the URL in shopify-reload, with a new session token in headers
      # patch_session_token_params["shopify-reload"] = bounce_url

      # redirect_to("#{patch_session_token_url}?#{patch_session_token_params.to_query}", allow_other_host: true)
      # end
    end

    def online_token_configured?
      ShopifyApp.configuration.online_token_configured?
    end
  end
end
