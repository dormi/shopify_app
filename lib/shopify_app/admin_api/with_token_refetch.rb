# frozen_string_literal: true

module ShopifyApp
  module AdminAPI
    module WithTokenRefetch
      def with_token_refetch(session, session_token)
        retrying = false if retrying.nil?
        yield
      rescue ShopifyAPI::Errors::HttpResponseError => error
        if error.code != 401
          ShopifyApp::Logger.debug("Encountered error: #{error.code} - #{error.response.inspect}, re-raising")
        elsif retrying
          ShopifyApp::Logger.debug("Shopify API returned a 401 Unauthorized error that was not corrected " \
            "with token exchange, deleting current session and re-raising")
          ShopifyApp::SessionRepository.delete_session(session.id)
        else
          retrying = true
          ShopifyApp::Logger.debug("Shopify API returned a 401 Unauthorized error, exchanging token and " \
            "retrying with new session")
          new_session = ShopifyApp::Auth::TokenExchange.perform(session_token)
          copy_session_attributes(from: new_session, to: session)
          retry
        end
        raise
      end

      private

      def copy_session_attributes(from:, to:)
        to.shop = from.shop
        to.state = from.state
        to.access_token = from.access_token
        to.scope = from.scope
        to.associated_user_scope = from.associated_user_scope
        to.expires = from.expires
        to.associated_user = from.associated_user
        to.shopify_session_id = from.shopify_session_id
      end
    end
  end
end
