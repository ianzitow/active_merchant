require 'test_helper'

class RemoteMaxipagoTest < Test::Unit::TestCase
  def setup
    @gateway = MaxipagoGateway.new(fixtures(:maxipago))

    @amount = 1000
    @invalid_amount = 2009
    @credit_card = credit_card('4111111111111111', verification_value: '444')
    @invalid_card = credit_card('4111111111111111', year: Time.now.year - 1)

    @options = {
      order_id: '12345',
      billing_address: address,
      description: 'Store Purchase',
      installments: 3
    }
    @options[:billing_address][:email] = 'jim_smith@email.com'
  end

  def test_successful_authorize
    assert response = @gateway.authorize(@amount, @credit_card, @options)
    assert_success response
    assert_equal "AUTHORIZED", response.message
  end

  def test_failed_authorize
    assert response = @gateway.authorize(@amount, @invalid_card, @options)
    assert_failure response
    assert_equal "The transaction has an expired credit card.", response.message
  end

  def test_successful_authorize_and_capture
    amount = @amount
    authorize = @gateway.authorize(amount, @credit_card, @options)
    assert_success authorize

    capture = @gateway.capture(amount, authorize.authorization, @options)
    assert_success capture
  end

  def test_successful_purchase
    assert response = @gateway.purchase(@amount, @credit_card, @options)
    assert_success response
  end

  def test_successful_purchase_sans_options
    assert response = @gateway.purchase(@amount, @credit_card)
    assert_success response
  end

  def test_successful_purchase_with_currency
    assert response = @gateway.purchase(@amount, @credit_card, @options.merge(currency: "CLP"))
    assert_success response
  end

  def test_failed_purchase
    assert response = @gateway.purchase(@invalid_amount, @credit_card, @options)
    assert_failure response
  end

  def test_failed_capture
    assert response = @gateway.capture(@amount, 'bogus')
    assert_failure response
  end

  def test_successful_void
    auth = @gateway.authorize(@amount, @credit_card, @options)
    assert_success auth

    void = @gateway.void(auth.authorization)
    assert_success void
    assert_equal "VOIDED", void.message
  end

  def test_failed_void
    response = @gateway.void("NOAUTH|0000000")
    assert_failure response
    assert_equal "Unable to validate, original void transaction not found", response.message
  end

  def test_successful_refund
    purchase = @gateway.purchase(@amount, @credit_card, @options)
    assert_success purchase

    refund = @gateway.refund(@amount, purchase.authorization, @options)
    assert_success refund
    assert_equal "CAPTURED", refund.message
  end

  def test_failed_refund
    purchase = @gateway.purchase(@amount, @credit_card, @options)
    assert_success purchase

    refund_amount = @amount + 10
    refund = @gateway.refund(refund_amount, purchase.authorization, @options)
    assert_failure refund
    assert_equal "The Return amount is greater than the amount that can be returned.", refund.message
  end

  def test_successful_verify
    response = @gateway.verify(@credit_card, @options)
    assert_success response
    assert_equal "AUTHORIZED", response.message
  end

  def test_failed_verify
    response = @gateway.verify(@invalid_card, @options)
    assert_failure response
    assert_equal "The transaction has an expired credit card.", response.message
  end

  def test_transcript_scrubbing
    transcript = capture_transcript(@gateway) do
      @gateway.purchase(@amount, @credit_card, @options)
    end
    clean_transcript = @gateway.scrub(transcript)

    assert_scrubbed(@credit_card.number, clean_transcript)
    assert_scrubbed(@credit_card.verification_value.to_s, clean_transcript)
    assert_scrubbed(@gateway.options[:password], clean_transcript)
  end

  def test_invalid_login
    gateway = MaxipagoGateway.new(
      login: '',
      password: ''
    )
    response = gateway.purchase(@amount, @credit_card, @options)
    assert_failure response
  end

  def test_successful_add_consumer
    response = @gateway.add_consumer(1, 'John', 'Smith')
    assert_success response
    assert_match response.params['customer_id'], response.message
  end

  def test_failed_add_consumer
    response = @gateway.add_consumer(1, 'John', '')
    assert_failure response
    assert_equal 'lastName is a required field.', response.message
  end

  def test_successful_update_consumer
    response = @gateway.add_consumer(2, 'John', 'Smith')

    id = response.message
    response = @gateway.update_consumer(id, 2, 'Mario')

    assert_success response
  end

  def test_failed_update_consumer
    response = @gateway.add_consumer(2, 'John', 'Smith')

    id = response.message
    response = @gateway.update_consumer(id, nil, 'Mario')

    assert_failure response
    assert_equal 'Parser Error: URI=null Line=1: cvc-complex-type.2.4.a: Invalid content was found starting with element \'firstName\'. One of \'{customerIdExt}\' is expected.', response.message
  end

  def test_successful_delete_consumer
    response = @gateway.add_consumer(3, 'John', 'Smith')
    id = response.message
    response = @gateway.delete_consumer(id)
    assert_success response
  end

  def test_failed_delete_consumer
    response = @gateway.delete_consumer(-3)
    assert_failure response
    assert_equal 'Customer Id is not a valid number.', response.message
  end

  def test_successful_store
    id = @gateway.add_consumer(4, 'John', 'Smith').message
    @options[:consumer_id] = id
    response = @gateway.store(@credit_card, @options)

    assert_success response
    assert_equal response.params['token'], response.message
  end

  def test_failed_store
    options = @options
    options[:billing_address][:email] = nil
    options[:consumer_id] = 4321
    response = @gateway.store(@credit_card, @options)

    assert_failure response
    assert_equal response.params['error_message'], response.message
  end

  def test_successful_unstore
    id = @gateway.add_consumer(5, 'John', 'Smith').message
    @options[:consumer_id] = id
    token = @gateway.store(@credit_card, @options).message
    response = @gateway.unstore(token, consumer_id: id)
    assert_success response
  end

  def test_failed_unstore
    id = @gateway.add_consumer(5, 'John', 'Smith').message
    response = @gateway.unstore('invalid_stoken', consumer_id: id)
    assert_failure response
    assert_equal response.params['error_message'], response.message
  end

  def test_successful_tokenized_purchase
    id = @gateway.add_consumer(5, 'John', 'Smith').message
    @options[:consumer_id] = id
    token = @gateway.store(@credit_card, @options).message
    @options[:token] = token
    response = @gateway.purchase(@amount, nil, @options)

    assert_success response
    assert_equal "CAPTURED", response.message
  end

  def test_failed_tokenized_purchase
    id = @gateway.add_consumer(5, 'John', 'Smith').message
    @options[:consumer_id] = id
    token = @gateway.store(@credit_card, @options).message
    @options[:token] = token
    response = @gateway.purchase(@invalid_amount, nil, @options)

    assert_failure response
    assert_equal "DECLINED", response.message
  end

  def test_successful_tokenized_purchase_with_cvv
    id = @gateway.add_consumer(5, 'John', 'Smith').message
    @options[:consumer_id] = id
    token = @gateway.store(@credit_card, @options).message
    @options[:token] = token
    @options[:cvv] = '444'
    response = @gateway.purchase(@amount, nil, @options)

    assert_success response
    assert_equal "CAPTURED", response.message
  end

  def test_successful_tokenized_authorize
    id = @gateway.add_consumer(5, 'John', 'Smith').message
    @options[:consumer_id] = id
    token = @gateway.store(@credit_card, @options).message
    @options[:token] = token
    response = @gateway.authorize(@amount, nil, @options)

    assert_success response
    assert_equal "AUTHORIZED", response.message
  end

  def test_successful_tokenized_authorize_with_cvv
    id = @gateway.add_consumer(5, 'John', 'Smith').message
    @options[:consumer_id] = id
    token = @gateway.store(@credit_card, @options).message
    @options[:token] = token
    @options[:cvv] = '444'
    response = @gateway.authorize(@amount, nil, @options)

    assert_success response
    assert_equal "AUTHORIZED", response.message
  end

  def test_failed_tokenized_authorize
    id = @gateway.add_consumer(5, 'John', 'Smith').message
    @options[:consumer_id] = id
    token = @gateway.store(@credit_card, @options).message
    @options[:token] = token
    response = @gateway.authorize(@invalid_amount, nil, @options)

    assert_failure response
    assert_equal "DECLINED", response.message
  end
end
