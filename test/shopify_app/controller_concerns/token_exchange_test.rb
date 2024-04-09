# frozen_string_literal: true

require "test_helper"
require "action_controller"
require "action_controller/base"

class ApiClass
  def self.perform; end
end

class TokenExchangeController < ActionController::Base
  include ShopifyApp::TokenExchange

  around_action :activate_shopify_session

  def index
    render(plain: "OK")
  end

  def make_api_call
    ApiClass.perform
    render(plain: "OK")
  end
end

class MockPostAuthenticateTasks
  def self.perform(session)
  end
end

class TokenExchangeControllerTest < ActionController::TestCase
  tests TokenExchangeController

  setup do
    @shop = "my-shop.myshopify.com"
    ShopifyApp::JWT.any_instance.stubs(:shopify_domain).returns(@shop)

    @session_token = "this-is-a-session-token"
    @session_token_in_header = "Bearer #{@session_token}"
    request.headers["HTTP_AUTHORIZATION"] = @session_token_in_header

    ShopifyApp::SessionRepository.shop_storage = ShopifyApp::InMemoryShopSessionStore
    ShopifyApp::SessionRepository.user_storage = nil

    @user = ShopifyAPI::Auth::AssociatedUser.new(
      id: 1,
      first_name: "Hello",
      last_name: "World",
      email: "Email",
      email_verified: true,
      account_owner: true,
      locale: "en",
      collaborator: false,
    )
    @online_session = ShopifyAPI::Auth::Session.new(
      id: "online_session_1",
      shop: @shop,
      is_online: true,
      associated_user: @user,
    )
    @offline_session = ShopifyAPI::Auth::Session.new(id: "offline_session_1", shop: @shop)

    @offline_session_id = "offline_#{@shop}"
    @online_session_id = "online_#{@user.id}"

    ShopifyApp.configuration.check_session_expiry_date = false
    ShopifyApp.configuration.custom_post_authenticate_tasks = MockPostAuthenticateTasks
  end

  test "Exchanges token when session doesn't exist" do
    with_application_test_routes do
      ShopifyAPI::Utils::SessionUtils.stubs(:current_session_id).with(
        @session_token_in_header,
        nil,
        false,
      ).returns(nil, @offline_session_id)

      ShopifyApp::Auth::TokenExchange.expects(:perform).with(@session_token) do
        ShopifyApp::SessionRepository.store_session(@offline_session)
      end

      ShopifyAPI::Context.expects(:activate_session).with(@offline_session)

      get :index, params: { shop: @shop }
    end
  end

  test "Use existing shop session if it exists" do
    ShopifyApp::SessionRepository.store_shop_session(@offline_session)

    with_application_test_routes do
      ShopifyAPI::Utils::SessionUtils.stubs(:current_session_id).with(
        @session_token_in_header,
        nil,
        false,
      ).returns(@offline_session_id)

      ShopifyApp::Auth::TokenExchange.expects(:perform).never

      ShopifyAPI::Context.expects(:activate_session).with(@offline_session)

      get :index, params: { shop: @shop }
    end
  end

  test "Use existing user session if it exists" do
    ShopifyApp::SessionRepository.user_storage = ShopifyApp::InMemoryUserSessionStore
    ShopifyApp::SessionRepository.store_user_session(@online_session, @user)

    with_application_test_routes do
      ShopifyAPI::Utils::SessionUtils.stubs(:current_session_id).with(
        @session_token_in_header,
        nil,
        true,
      ).returns(@online_session_id)

      ShopifyApp::Auth::TokenExchange.expects(:perform).never

      ShopifyAPI::Context.expects(:activate_session).with(@online_session)

      get :index, params: { shop: @shop }
    end
  end

  test "Exchange token again if current user session is expired" do
    ShopifyApp.configuration.check_session_expiry_date = true
    ShopifyApp::SessionRepository.user_storage = ShopifyApp::InMemoryUserSessionStore
    ShopifyApp::SessionRepository.store_user_session(@online_session, @user)
    @online_session.stubs(:expired?).returns(true)

    with_application_test_routes do
      ShopifyAPI::Utils::SessionUtils.stubs(:current_session_id).with(
        @session_token_in_header,
        nil,
        true,
      ).returns(@online_session_id)

      ShopifyApp::Auth::TokenExchange.expects(:perform).with(@session_token) do
        ShopifyApp::SessionRepository.store_session(@offline_session)
        ShopifyApp::SessionRepository.store_session(@online_session)
      end

      ShopifyAPI::Context.expects(:activate_session).with(@online_session)

      get :index, params: { shop: @shop }
    end
  end

  test "Don't exchange token if check_session_expiry_date config is false" do
    ShopifyApp.configuration.check_session_expiry_date = false
    ShopifyApp::SessionRepository.user_storage = ShopifyApp::InMemoryUserSessionStore
    ShopifyApp::SessionRepository.store_user_session(@online_session, @user)
    @online_session.stubs(:expired?).returns(true)

    with_application_test_routes do
      ShopifyAPI::Utils::SessionUtils.stubs(:current_session_id).with(
        @session_token_in_header,
        nil,
        true,
      ).returns(@online_session_id)

      ShopifyApp::Auth::TokenExchange.expects(:perform).never

      ShopifyAPI::Context.expects(:activate_session).with(@online_session)

      get :index, params: { shop: @shop }
    end
  end

  # test "Handles 401 error by exchanging token before retrying with new access token" do
  #   ShopifyApp::SessionRepository.store_shop_session(@offline_session)
  #   ShopifyAPI::Utils::SessionUtils.stubs(:current_session_id).returns(@offline_session_id)

  #   ApiClass.expects(:perform).times(2)
  #     .raises(http_response_401_error)
  #     .then.returns(true)

  #   ShopifyAPI::Auth::TokenExchange.expects(:exchange_token).with(
  #     shop: @shop,
  #     session_token: @session_token,
  #     requested_token_type: ShopifyAPI::Auth::TokenExchange::RequestedTokenType::OFFLINE_ACCESS_TOKEN,
  #   ).returns(@offline_session)

  #   with_application_test_routes do
  #     get :make_api_call, params: { shop: @shop }
  #   end
  # end

  # test "Only retry once when encountering 401 error and raises the second error" do
  #   ShopifyApp::SessionRepository.store_shop_session(@offline_session)
  #   ShopifyAPI::Utils::SessionUtils.stubs(:current_session_id).returns(@offline_session_id)
  #   ShopifyAPI::Auth::TokenExchange.stubs(:exchange_token).returns(@offline_session)

  #   ApiClass.expects(:perform).times(2).raises(http_response_401_error)

  #   with_application_test_routes do
  #     actual_error = assert_raises(ShopifyAPI::Errors::HttpResponseError) do
  #       get :make_api_call, params: { shop: @shop }
  #     end

  #     assert_equal http_response_401_error.code, actual_error.code
  #   end
  # end

  # test "Raises HttpResponseError without retrying if not a 401 error" do
  #   ShopifyApp::SessionRepository.store_shop_session(@offline_session)
  #   ShopifyAPI::Utils::SessionUtils.stubs(:current_session_id).returns(@offline_session_id)
  #   ShopifyAPI::Auth::TokenExchange.stubs(:exchange_token).returns(@offline_session)

  #   ApiClass.expects(:perform).raises(http_response_500_error)

  #   with_application_test_routes do
  #     actual_error = assert_raises(ShopifyAPI::Errors::HttpResponseError) do
  #       get :make_api_call, params: { shop: @shop }
  #     end

  #     assert_equal http_response_500_error.code, actual_error.code
  #   end
  # end

  private

  def with_application_test_routes
    with_routing do |set|
      set.draw do
        get "/" => "token_exchange#index"
        get "/make_api_call" => "token_exchange#make_api_call"
      end
      yield
    end
  end

  # def http_response_401_error
  #   ShopifyAPI::Errors::HttpResponseError.new(
  #     response: ShopifyAPI::Clients::HttpResponse.new(
  #       code: 401,
  #       headers: {},
  #       body: "Invalid API key or access token (unrecognized login or wrong password)",
  #     ),
  #   )
  # end

  # def http_response_500_error
  #   ShopifyAPI::Errors::HttpResponseError.new(
  #     response: ShopifyAPI::Clients::HttpResponse.new(
  #       code: 500,
  #       headers: {},
  #       body: "Internal Server Error",
  #     ),
  #   )
  # end
end
