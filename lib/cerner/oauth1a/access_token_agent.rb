# frozen_string_literal: true

require 'base64'
require 'cerner/oauth1a/access_token'
require 'cerner/oauth1a/keys'
require 'cerner/oauth1a/oauth_error'
require 'cerner/oauth1a/cache'
require 'cerner/oauth1a/internal'
require 'cerner/oauth1a/protocol'
require 'cerner/oauth1a/signature'
require 'cerner/oauth1a/version'
require 'json'
require 'net/http'
require 'securerandom'
require 'uri'

module Cerner
  module OAuth1a
    # Public: A user agent (client) for interacting with the Cerner OAuth 1.0a Access Token service to acquire
    # consumer Access Tokens or service provider Keys.
    class AccessTokenAgent
      MIME_WWW_FORM_URL_ENCODED = 'application/x-www-form-urlencoded'

      DEFAULT_REALM_ALIASES = {
        'https://oauth-api.cerner.com' => ['https://api.cernercare.com'].freeze,
        'https://api.cernercare.com' => ['https://oauth-api.cerner.com'].freeze,
        'https://oauth-api.sandboxcerner.com' => ['https://api.sandboxcernercare.com'].freeze,
        'https://api.sandboxcernercare.com' => ['https://oauth-api.sandboxcerner.com'].freeze,
        'https://oauth-api.devcerner.com' => ['https://api.devcernercare.com'].freeze,
        'https://api.devcernercare.com' => ['https://oauth-api.devcerner.com'].freeze
      }.freeze

      # Returns the URI Access Token URL.
      attr_reader :access_token_url
      # Returns the String Consumer Key.
      attr_reader :consumer_key
      # Returns the String Consumer Secret.
      attr_reader :consumer_secret
      # Returns the String Protection Realm. The realm is root of the access_token_url (Protocol#realm_for).
      attr_reader :realm
      # Returns the Array of Protection Realm String that are considered equivalent (#realm_eql?) to #realm.
      attr_reader :realm_aliases

      # Public: Constructs an instance of the agent.
      #
      # _Caching_
      #
      # By default, AccessToken and Keys instances are maintained in a small, constrained
      # memory cache used by #retrieve and #retrieve_keys, respectively.
      #
      # The AccessToken cache keeps a maximum of 5 entries and prunes them when they expire. As the
      # cache is based on the #consumer_key and the 'principal' parameter, the cache has limited
      # effect. It's strongly suggested that AccessToken's be cached independently, as well.
      #
      # The Keys cache keeps a maximum of 10 entries and prunes them 24 hours after retrieval.
      #
      # arguments - The keyword arguments of the method:
      #             :access_token_url    - The String or URI of the Access Token service endpoint.
      #             :consumer_key        - The String of the Consumer Key of the account.
      #             :consumer_secret     - The String of the Consumer Secret of the account.
      #             :open_timeout        - An object responding to to_i. Used to set the timeout, in
      #                                    seconds, for opening HTTP connections to the Access Token
      #                                    service (optional, default: 5).
      #             :read_timeout        - An object responding to to_i. Used to set the timeout, in
      #                                    seconds, for reading data from HTTP connections to the
      #                                    Access Token service (optional, default: 5).
      #             :cache_keys          - A Boolean for configuring Keys caching within
      #                                    #retrieve_keys. (optional, default: true)
      #             :cache_access_tokens - A Boolean for configuring AccessToken caching within
      #                                    #retrieve. (optional, default: true)
      #             :realm_aliases       - An Array of Strings that provide realm aliases for the
      #                                    realm that's extracted from :access_token_url. If nil,
      #                                    this will be initalized with the DEFAULT_REALM_ALIASES.
      #                                    (optional, default: nil)
      #             :signature_method    - A String to set the signature method to use. MUST be
      #                                    PLAINTEXT or HMAC-SHA1. (optional, default: 'PLAINTEXT')
      #
      # Raises ArgumentError if access_token_url, consumer_key or consumer_key is nil; if
      #                      access_token_url is an invalid URI; if signature_method is invalid.
      def initialize(
        access_token_url:,
        consumer_key:,
        consumer_secret:,
        open_timeout: 5,
        read_timeout: 5,
        cache_keys: true,
        cache_access_tokens: true,
        realm_aliases: nil,
        signature_method: 'PLAINTEXT'
      )
        raise ArgumentError, 'consumer_key is nil' unless consumer_key
        raise ArgumentError, 'consumer_secret is nil' unless consumer_secret

        @consumer_key = consumer_key
        @consumer_secret = consumer_secret

        @access_token_url = Internal.convert_to_http_uri(url: access_token_url, name: 'access_token_url')
        @realm = Protocol.realm_for(@access_token_url)
        @realm_aliases = realm_aliases
        @realm_aliases ||= DEFAULT_REALM_ALIASES[@realm]

        @open_timeout = (open_timeout ? open_timeout.to_i : 5)
        @read_timeout = (read_timeout ? read_timeout.to_i : 5)

        @keys_cache = cache_keys ? Cache.instance : nil
        @access_token_cache = cache_access_tokens ? Cache.instance : nil

        @signature_method = signature_method || 'PLAINTEXT'
        raise ArgumentError, 'signature_method is invalid' unless Signature::METHODS.include?(@signature_method)
      end

      # Public: Retrieves the service provider keys from the configured Access Token service endpoint
      # (@access_token_url). This method will invoke #retrieve to acquire an AccessToken to request
      # the keys.
      #
      # keys_version - The version identifier of the keys to retrieve. This corresponds to the
      #                KeysVersion parameter of the oauth_token.
      # keywords     - The keyword arguments:
      #               :ignore_cache - A flag for indicating that the cache should be ignored and a
      #                               new Access Token should be retrieved.
      #
      # Return a Keys instance upon success.
      #
      # Raises ArgumentError if keys_version is nil.
      # Raises OAuthError for any functional errors returned within an HTTP 200 response.
      # Raises StandardError sub-classes for any issues interacting with the service, such as networking issues.
      def retrieve_keys(keys_version, ignore_cache: false)
        raise ArgumentError, 'keys_version is nil' unless keys_version

        if @keys_cache && !ignore_cache
          cache_entry = @keys_cache.get('cerner-oauth1a/keys', keys_version)
          return cache_entry.value if cache_entry
        end

        request = retrieve_keys_prepare_request(keys_version)
        response = http_client.request(request)
        keys = retrieve_keys_handle_response(keys_version, response)
        @keys_cache&.put('cerner-oauth1a/keys', keys_version, Cache::KeysEntry.new(keys, Cache::TWENTY_FOUR_HOURS))
        keys
      end

      # Public: Retrieves an AccessToken from the configured Access Token service endpoint (#access_token_url).
      # This method will use the #generate_accessor_secret, #generate_nonce and #generate_timestamp methods to
      # interact with the service, which can be overridden via a sub-class, if desired.
      #
      # keywords - The keyword arguments:
      #            :principal    - An optional principal identifier, which is passed via the
      #                            xoauth_principal protocol parameter.
      #            :ignore_cache - A flag for indicating that the cache should be ignored and a new
      #                            Access Token should be retrieved.
      #
      # Returns a AccessToken upon success.
      #
      # Raises OAuthError for any functional errors returned within an HTTP 200 response.
      # Raises StandardError sub-classes for any issues interacting with the service, such as networking issues.
      def retrieve(principal: nil, ignore_cache: false)
        cache_key = "#{@consumer_key}&#{principal}"

        if @access_token_cache && !ignore_cache
          cache_entry = @access_token_cache.get('cerner-oauth1a/access-tokens', cache_key)
          return cache_entry.value if cache_entry
        end

        # generate token request info
        timestamp = generate_timestamp
        accessor_secret = generate_accessor_secret

        request = retrieve_prepare_request(timestamp: timestamp, accessor_secret: accessor_secret, principal: principal)
        response = http_client.request(request)
        access_token =
          retrieve_handle_response(response: response, timestamp: timestamp, accessor_secret: accessor_secret)
        @access_token_cache&.put('cerner-oauth1a/access-tokens', cache_key, Cache::AccessTokenEntry.new(access_token))
        access_token
      end

      # Public: Generate an Accessor Secret for invocations of the Access Token service.
      #
      # Returns a String containing the secret.
      def generate_accessor_secret
        SecureRandom.uuid
      end

      # Public: Generate a Nonce for invocations of the Access Token service.
      #
      # Returns a String containing the nonce.
      def generate_nonce
        Internal.generate_nonce
      end

      # Public: Generate a Timestamp for invocations of the Access Token service.
      #
      # Returns an Integer representing the number of seconds since the epoch.
      def generate_timestamp
        Internal.generate_timestamp
      end

      # Public: Determines if the passed realm is equivalent to the configured
      # realm by comparing it to the #realm and #realm_aliases.
      #
      # realm - The String to check for equivalence.
      #
      # Returns True if the passed realm is equivalent to the configured realm;
      #   False otherwise.
      def realm_eql?(realm)
        return true if @realm.eql?(realm)

        @realm_aliases.include?(realm)
      end

      private

      # Internal: Generate a User-Agent HTTP Header string
      def user_agent_string
        "cerner-oauth1a #{VERSION} (Ruby #{RUBY_VERSION})"
      end

      # Internal: Provide the HTTP client instance for invoking requests
      def http_client
        http = Net::HTTP.new(@access_token_url.host, @access_token_url.port)

        if @access_token_url.scheme == 'https'
          # if the scheme is HTTPS, then enable SSL
          http.use_ssl = true
          # make sure to verify peers
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          # tweak the ciphers to eliminate unsafe options
          http.ciphers = 'DEFAULT:!aNULL:!eNULL:!LOW:!SSLv2:!RC4'
        end

        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout

        http
      end

      # Internal: Prepare a request for #retrieve
      def retrieve_prepare_request(accessor_secret:, timestamp:, principal: nil)
        # construct a POST request
        request = Net::HTTP::Post.new(@access_token_url)
        # setup the data to construct the POST's message
        params = {
          oauth_consumer_key: Protocol.percent_encode(@consumer_key),
          oauth_signature_method: @signature_method,
          oauth_version: '1.0',
          oauth_accessor_secret: accessor_secret
        }
        params[:xoauth_principal] = principal.to_s if principal

        if @signature_method == 'PLAINTEXT'
          sig = Signature.sign_via_plaintext(client_shared_secret: @consumer_secret, token_shared_secret: '')
        elsif @signature_method == 'HMAC-SHA1'
          params[:oauth_timestamp] = timestamp
          params[:oauth_nonce] = generate_nonce
          signature_base_string =
            Signature.build_signature_base_string(
              http_method: 'POST', fully_qualified_url: @access_token_url, params: params
            )
          sig =
            Signature.sign_via_hmacsha1(
              client_shared_secret: @consumer_secret,
              token_shared_secret: '',
              signature_base_string: signature_base_string
            )
        else
          raise OAuthError.new('signature_method is invalid', nil, 'signature_method_rejected', nil, @realm)
        end

        params[:oauth_signature] = sig

        params = params.map { |n, v| [n, v] }
        # set the POST's body as a URL form-encoded string
        request.set_form(params, MIME_WWW_FORM_URL_ENCODED, charset: 'UTF-8')
        request['Accept'] = MIME_WWW_FORM_URL_ENCODED
        # Set a custom User-Agent to help identify these invocation
        request['User-Agent'] = user_agent_string
        request
      end

      # Internal: Handle a response for #retrieve
      def retrieve_handle_response(response:, timestamp:, accessor_secret:)
        case response
        when Net::HTTPSuccess
          # Parse the HTTP response and convert it into a Symbol-keyed Hash
          tuples = Protocol.parse_url_query_string(response.body)
          # Use the parsed response to construct the AccessToken
          access_token =
            AccessToken.new(
              accessor_secret: accessor_secret,
              consumer_key: @consumer_key,
              expires_at: timestamp + tuples[:oauth_expires_in].to_i,
              token: tuples[:oauth_token],
              token_secret: tuples[:oauth_token_secret],
              signature_method: @signature_method,
              realm: @realm
            )
          access_token
        else
          # Extract any OAuth Problems reported in the response
          oauth_data = Protocol.parse_authorization_header(response['WWW-Authenticate'])
          # Raise an error for a failure to acquire a token
          raise OAuthError.new('unable to acquire token', response.code, oauth_data[:oauth_problem], nil, @realm)
        end
      end

      # Internal: Prepare a request for #retrieve_keys
      def retrieve_keys_prepare_request(keys_version)
        keys_url = URI("#{@access_token_url}/keys/#{keys_version}")
        request = Net::HTTP::Get.new(keys_url)
        request['Accept'] = 'application/json'
        request['User-Agent'] = user_agent_string
        request['Authorization'] = retrieve.authorization_header(fully_qualified_url: keys_url)
        request
      end

      # Internal: Handle a response for #retrieve_keys
      def retrieve_keys_handle_response(keys_version, response)
        case response
        when Net::HTTPSuccess
          parsed_response = JSON.parse(response.body)
          aes_key = parsed_response.dig('aesKey', 'secretKey')
          raise OAuthError.new('AES secret key retrieved was invalid', nil, nil, nil, @realm) unless aes_key

          rsa_key = parsed_response.dig('rsaKey', 'publicKey')
          raise OAuthError.new('RSA public key retrieved was invalid', nil, nil, nil, @realm) unless rsa_key

          Keys.new(
            version: keys_version, aes_secret_key: Base64.decode64(aes_key), rsa_public_key: Base64.decode64(rsa_key)
          )
        else
          # Extract any OAuth Problems reported in the response
          oauth_data = Protocol.parse_authorization_header(response['WWW-Authenticate'])
          # Raise an error for a failure to acquire keys
          raise OAuthError.new('unable to acquire keys', response.code, oauth_data[:oauth_problem], nil, @realm)
        end
      end
    end
  end
end
