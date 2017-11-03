require 'nokogiri'

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class MaxipagoGateway < Gateway
      API_VERSION = '3.1.1.15'

      class_attribute :test_api_url, :live_api_url
      class_attribute :test_rapi_url, :live_rapi_url

      self.live_url = 'https://api.maxipago.net/UniversalAPI/postXML'
      self.test_url = 'https://testapi.maxipago.net/UniversalAPI/postXML'

      self.live_api_url = 'https://api.maxipago.net/UniversalAPI/postAPI'
      self.test_api_url = 'https://testapi.maxipago.net/UniversalAPI/postAPI'

      self.test_rapi_url = 'https://api.maxipago.net/ReportsAPI/servlet/ReportsAPI'
      self.test_rapi_url = 'https://testapi.maxipago.net/ReportsAPI/servlet/ReportsAPI'

      self.supported_countries = ['BR']
      self.default_currency = 'BRL'
      self.money_format = :dollars
      self.supported_cardtypes = [:visa, :master, :discover, :american_express, :diners_club]
      self.homepage_url = 'http://www.maxipago.com/'
      self.display_name = 'maxiPago!'

      def initialize(options = {})
        requires!(options, :login, :password)
        super
      end

      def purchase(money, creditcard, options = {})
        commit_transaction(:sale) do |xml|
          add_auth_purchase(xml, money, creditcard, options)
        end
      end

      def authorize(money, creditcard, options = {})
        commit_transaction(:auth) do |xml|
          add_auth_purchase(xml, money, creditcard, options)
        end
      end

      def capture(money, authorization, options = {})
        commit_transaction(:capture) do |xml|
          add_order_id(xml, authorization)
          add_reference_num(xml, options)
          xml.payment do
            add_amount(xml, money, options)
          end
        end
      end

      def void(authorization, options = {})
        _, transaction_id = split_authorization(authorization)
        commit_transaction(:void) do |xml|
          xml.transactionID transaction_id
        end
      end

      def refund(money, authorization, options = {})
        commit_transaction(:return) do |xml|
          add_order_id(xml, authorization)
          add_reference_num(xml, options)
          xml.payment do
            add_amount(xml, money, options)
          end
        end
      end

      def verify(creditcard, options = {})
        MultiResponse.run(:use_first_response) do |r|
          r.process { authorize(100, creditcard, options) }
          r.process(:ignore_result) { void(r.authorization, options) }
        end
      end

      def add_consumer(external_id, first_name, last_name)
        commit_api("add-consumer") do |xml|
          xml.customerIdExt external_id
          xml.firstName first_name
          xml.lastName last_name
        end
      end

      def update_consumer(consumer_id, external_id = nil, first_name = '', last_name = '')
        # raise(ArgumentError, 'A gateway provider must be specified') if external_id.nil?

        commit_api("update-consumer") do |xml|
          xml.customerId consumer_id
          xml.customerIdExt external_id if external_id.present?
          xml.firstName first_name if first_name.present?
          xml.lastName last_name if last_name.present?
        end
      end

      def delete_consumer(consumer_id)
        commit_api("delete-consumer") do |xml|
          xml.customerId consumer_id
        end
      end

      def add_card(consumer_id, creditcard, options = {})
        commit_api("add-card-onfile") do |xml|
          xml.customerId consumer_id
          add_new_creditcard(xml, creditcard, options)
        end
      end

      def delete_card(consumer_id, token)
        commit_api("delete-card-onfile") do |xml|
          xml.customerId consumer_id
          xml.token token
        end
      end

      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        transcript.
          gsub(%r((<merchantKey>)[^<]*(</merchantKey>))i, '\1[FILTERED]\2').
          gsub(%r((<number>)[^<]*(</number>))i, '\1[FILTERED]\2').
          gsub(%r((<cvvNumber>)[^<]*(</cvvNumber>))i, '\1[FILTERED]\2')
      end

      private

      def commit_transaction(action)
        request = build_transaction_request(action) { |doc| yield(doc) }
        response = parse(ssl_post(transaction_url, request, 'Content-Type' => 'text/xml'))

        generate_response(response)
      end

      def commit_api(action)
        request = build_api_request(action) { |doc| yield(doc) }
        response = parse ssl_post(api_url, request, 'Content-Type' => 'text/xml')
        generate_response(response)
      end

      def generate_response(response)
        Response.new(
          success?(response),
          message_from(response),
          response,
          test: test?,
          authorization: authorization_from(response)
        )
      end

      def transaction_url
        test? ? self.test_url : self.live_url
      end

      def api_url
        test? ? self.test_api_url : self.live_api_url
      end

      def rapi_url
        test? ? self.test_rapi_url : self.live_rapi_url
      end

      def build_transaction_request(action)
        builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8')
        builder.send("transaction-request") do |xml|
          xml.version '3.1.1.15'
          xml.verification do
            xml.merchantId @options[:login]
            xml.merchantKey @options[:password]
          end
          xml.order do
            xml.send("#{action}!") do
              yield(xml)
            end
          end
        end

        builder.to_xml(indent: 2)
      end

      def build_api_request(action)
        builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8')
        builder.send("api-request") do |xml|
          xml.verification do
            xml.merchantId @options[:login]
            xml.merchantKey @options[:password]
          end
          xml.command "#{action}"
          xml.send("request!") do
            yield(xml)
          end
        end

        builder.to_xml(indent: 2)
      end

      def success?(response)
        (response[:response_code] || response[:error_code]) == '0'
      end

      def message_from(response)
        response[:error_message] || response[:response_message] || response[:processor_message] || response[:error_msg] || response[:customer_id] || response[:token]
      end

      def authorization_from(response)
        "#{response[:order_id]}|#{response[:transaction_id]}"
      end

      def split_authorization(authorization)
        authorization.split("|")
      end

      def parse(body)
        xml = REXML::Document.new(body)

        response = {}
        xml.root.elements.to_a.each do |node|
          parse_element(response, node)
        end
        response
      end

      def parse_element(response, node)
        if node.has_elements?
          node.elements.each{|element| parse_element(response, element) }
        else
          response[node.name.underscore.to_sym] = node.text
        end
      end

      def add_auth_purchase(xml, money, creditcard, options)
        fraudCheck = options[:fraud_check] || 'N'

        add_processor_id(xml)
        xml.fraudCheck(fraudCheck)
        add_reference_num(xml, options)
        xml.transactionDetail do
          xml.payType do
            xml.creditCard do
              xml.number(creditcard.number)
              xml.expMonth(creditcard.month)
              xml.expYear(creditcard.year)
              xml.cvvNumber(creditcard.verification_value)
            end
          end
        end
        xml.payment do
          add_amount(xml, money, options)
          add_installments(xml, options)
        end
        add_billing_address(xml, creditcard, options)
      end

      def add_reference_num(xml, options)
        xml.referenceNum(options[:order_id] || generate_unique_id)
      end

      def add_amount(xml, money, options)
        xml.chargeTotal(amount(money))
        xml.currencyCode(options[:currency] || currency(money) || default_currency)
      end

      def add_processor_id(xml)
        if test?
          xml.processorID(1)
        else
          xml.processorID(@options[:processor_id] || 4)
        end
      end

      def add_installments(xml, options)
        if options.has_key?(:installments) && options[:installments] > 1
          xml.creditInstallment do
            xml.numberOfInstallments options[:installments]
            xml.chargeInterest 'N'
          end
        end
      end

      def add_billing_address(xml, creditcard, options)
        address = options[:billing_address]
        return unless address

        xml.billing do
          xml.name creditcard.name
          xml.address address[:address1] if address[:address1]
          xml.address2 address[:address2] if address[:address2]
          xml.city address[:city] if address[:city]
          xml.state address[:state] if address[:state]
          xml.postalcode address[:zip] if address[:zip]
          xml.country address[:country] if address[:country]
          xml.phone address[:phone] if address[:phone]
        end
      end

      def add_new_creditcard(xml, creditcard, options)
        address = options[:billing_address]
        max_charge_amount = options[:max_charge_amount]
        return unless address

        year = creditcard.year.to_s
        year = (year.length == 4 ? year : '20' + year)

        month = creditcard.month.to_s
        month = (month.length == 2 ? month : '0' + month)

        xml.creditCardNumber creditcard.number
        xml.expirationMonth month
        xml.expirationYear year
        xml.billingName creditcard.name
        xml.billingAddress1 address[:address1] if address[:address1]
        xml.billingAddress2 address[:address2] if address[:address2]
        xml.billingCity address[:city] if address[:city]
        xml.billingZip address[:zip] if address[:zip]
        xml.billingCountry address[:country] if address[:country]
        xml.billingPhone address[:phone] if address[:phone]
        xml.billingEmail address[:email] if address[:email]
        xml.onFileMaxChargeAmount max_charge_amount if max_charge_amount.present?
      end

      def add_order_id(xml, authorization)
        order_id, _ = split_authorization(authorization)
        xml.orderID order_id
      end
    end
  end
end
