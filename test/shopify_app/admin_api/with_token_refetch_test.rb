# frozen_string_literal: true

require "test_helper"

class ShopifyApp::AdminAPI::WithTokenRefetchTest < ActiveSupport::TestCase
  include ShopifyApp::AdminAPI::WithTokenRefetch

  def setup
    @session = ShopifyAPI::Auth::Session.new(
      id: "id",
      shop: "shop",
      state: "aaa",
      access_token: "old-token",
      scope: "read_products,read_themes",
      associated_user_scope: "read_products",
      expires: 1.hour.ago,
      associated_user: build_user,
      is_online: true,
      shopify_session_id: "123",
    )
    @session_token = "a-session-token"

    @new_session = ShopifyAPI::Auth::Session.new(
      id: "id",
      shop: "shop",
      state: nil,
      access_token: "new-token",
      scope: "write_products,read_themes",
      associated_user_scope: "write_products",
      expires: 1.day.from_now,
      associated_user: build_user,
      is_online: true,
      shopify_session_id: "456",
    )

    @fake_admin_api = stub(:admin_api)
  end

  test "#with_token_refetch takes a block and returns its value" do
    result = with_token_refetch(@session, @session_token) do
      "returned by block"
    end

    assert_equal "returned by block", result
  end

  test "#with_token_refetch rescues Admin API HttpResponseError 401, performs token exchange and retries block" do
    response = ShopifyAPI::Clients::HttpResponse.new(code: 401, body: { error: "oops" }.to_json, headers: {})
    error = ShopifyAPI::Errors::HttpResponseError.new(response: response)
    @fake_admin_api.stubs(:query).raises(error).then.returns("oh now we're good")

    ShopifyApp::Logger.expects(:debug).with("Encountered 401 error, exchanging token and retrying " \
      "with new access token")

    ShopifyApp::Auth::TokenExchange.expects(:perform).with(@session_token).returns(@new_session)

    result = with_token_refetch(@session, @session_token) do
      @fake_admin_api.query
    end

    assert_equal "oh now we're good", result
  end

  test "#with_token_refetch updates original session's attributes when token exchange is performed" do
    response = ShopifyAPI::Clients::HttpResponse.new(code: 401, body: "", headers: {})
    error = ShopifyAPI::Errors::HttpResponseError.new(response: response)
    @fake_admin_api.stubs(:query).raises(error).then.returns("oh now we're good")

    ShopifyApp::Auth::TokenExchange.stubs(:perform).with(@session_token).returns(@new_session)

    with_token_refetch(@session, @session_token) do
      @fake_admin_api.query
    end

    assert_equal @new_session.shop, @session.shop
    assert_nil @session.state
    assert_equal @new_session.access_token, @session.access_token
    assert_equal @new_session.scope, @session.scope
    assert_equal @new_session.associated_user_scope, @session.associated_user_scope
    assert_equal @new_session.expires, @session.expires
    assert_equal @new_session.associated_user, @session.associated_user
    assert_equal @new_session.shopify_session_id, @session.shopify_session_id
  end

  test "#with_token_refetch re-raises when 401 persists" do
    response = ShopifyAPI::Clients::HttpResponse.new(code: 401, body: "401 message", headers: {})
    api_error = ShopifyAPI::Errors::HttpResponseError.new(response: response)

    ShopifyApp::Auth::TokenExchange.stubs(:perform).with(@session_token).returns(@new_session)

    @fake_admin_api.expects(:query).twice.raises(api_error)

    ShopifyApp::Logger.expects(:debug).with("Encountered 401 error, exchanging token and retrying " \
      "with new access token")
    ShopifyApp::Logger.expects(:debug).with(regexp_matches(/Encountered error: 401 \- .*401 message.*, re-raising/))

    reraised_error = assert_raises ShopifyAPI::Errors::HttpResponseError do
      with_token_refetch(@session, @session_token) do
        @fake_admin_api.query
      end
    end

    assert_equal reraised_error, api_error
  end

  test "#with_token_refetch re-raises when error is not a 401" do
    response = ShopifyAPI::Clients::HttpResponse.new(code: 500, body: { error: "ooops" }.to_json, headers: {})
    api_error = ShopifyAPI::Errors::HttpResponseError.new(response: response)

    @fake_admin_api.expects(:query).raises(api_error)
    ShopifyApp::Logger.expects(:debug).with(regexp_matches(/Encountered error: 500 \- .*ooops.*, re-raising/))

    reraised_error = assert_raises ShopifyAPI::Errors::HttpResponseError do
      with_token_refetch(@session, @session_token) do
        @fake_admin_api.query
      end
    end

    assert_equal reraised_error, api_error
  end

  private

  def build_user
    ShopifyAPI::Auth::AssociatedUser.new(
      id: 1,
      first_name: "Hello #{Time.now}",
      last_name: "World",
      email: "Email",
      email_verified: true,
      account_owner: true,
      locale: "en",
      collaborator: false,
    )
  end
end
