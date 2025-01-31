# frozen_string_literal: true

require "system_helper"

describe "As a consumer, I want to checkout my order", js: true do
  include ShopWorkflow
  include SplitCheckoutHelper
  include FileHelper

  let!(:zone) { create(:zone_with_member) }
  let(:supplier) { create(:supplier_enterprise) }
  let(:distributor) { create(:distributor_enterprise, charges_sales_tax: true) }
  let(:product) {
    create(:taxed_product, supplier: supplier, price: 10, zone: zone, tax_rate_amount: 0.1)
  }
  let(:variant) { product.variants.first }
  let!(:order_cycle) {
    create(:simple_order_cycle, suppliers: [supplier], distributors: [distributor],
                                coordinator: create(:distributor_enterprise), variants: [variant])
  }
  let(:order) {
    create(:order, order_cycle: order_cycle, distributor: distributor, bill_address_id: nil,
                   ship_address_id: nil, state: "cart",
                   line_items: [create(:line_item, variant: variant)])
  }

  let(:fee_tax_rate) { create(:tax_rate, amount: 0.10, zone: zone, included_in_price: true) }
  let(:fee_tax_category) { create(:tax_category, tax_rates: [fee_tax_rate]) }
  let(:enterprise_fee) { create(:enterprise_fee, amount: 1.23, tax_category: fee_tax_category) }

  let(:free_shipping) {
    create(:shipping_method, require_ship_address: false, name: "Free Shipping", description: "yellow",
                             calculator: Calculator::FlatRate.new(preferred_amount: 0.00))
  }
  let(:shipping_tax_rate) { create(:tax_rate, amount: 0.25, zone: zone, included_in_price: true) }
  let(:shipping_tax_category) { create(:tax_category, tax_rates: [shipping_tax_rate]) }
  let(:shipping_with_fee) {
    create(:shipping_method, require_ship_address: true, tax_category: shipping_tax_category,
                             name: "Shipping with Fee", description: "blue",
                             calculator: Calculator::FlatRate.new(preferred_amount: 4.56))
  }
  let!(:payment_method) { create(:payment_method, distributors: [distributor]) }

  before do
    allow(Flipper).to receive(:enabled?).with(:split_checkout).and_return(true)
    allow(Flipper).to receive(:enabled?).with(:split_checkout, anything).and_return(true)

    add_enterprise_fee enterprise_fee
    set_order order

    distributor.shipping_methods << free_shipping
    distributor.shipping_methods << shipping_with_fee
  end

  context "guest checkout when distributor doesn't allow guest orders" do
    before do
      distributor.update_columns allow_guest_orders: false
      visit checkout_step_path(:details)
    end

    it "should display the split checkout login page" do
      expect(page).to have_content("Ok, ready to checkout?")
      expect(page).to have_content("Login")
      expect(page).to have_no_content("Checkout as guest")
    end

    it "should show the login modal when clicking the login button" do
      click_on "Login"
      expect(page).to have_selector ".login-modal"
    end
  end

  context "as a guest user" do
    before do
      visit checkout_path
    end

    it "should display the split checkout login/guest form" do
      expect(page).to have_content distributor.name
      expect(page).to have_content("Ok, ready to checkout?")
      expect(page).to have_content("Login")
      expect(page).to have_content("Checkout as guest")
    end

    it "should display the split checkout details page" do
      click_on "Checkout as guest"
      expect(page).to have_content distributor.name
      expect(page).to have_content("1 - Your details")
      expect(page).to have_selector("div.checkout-tab.selected", text: "1 - Your details")
      expect(page).to have_content("2 - Payment method")
      expect(page).to have_content("3 - Order summary")
    end

    it "should display error when fields are empty" do
      click_on "Checkout as guest"
      click_button "Next - Payment method"
      expect(page).to have_content("Saving failed, please update the highlighted fields")
      expect(page).to have_css 'span.field_with_errors label', count: 6
      expect(page).to have_css 'span.field_with_errors input', count: 6
      expect(page).to have_css 'span.formError', count: 7
    end

    it "should validate once each needed field is filled" do
      click_on "Checkout as guest"
      fill_in "First Name", with: "Jane"
      fill_in "Last Name", with: "Doe"
      fill_in "Phone number", with: "07987654321"
      fill_in "Address (Street + House Number)", with: "Flat 1 Elm apartments"
      fill_in "City", with: "London"
      fill_in "Postcode", with: "SW1A 1AA"
      choose free_shipping.name

      click_button "Next - Payment method"
      expect(page).to have_button("Next - Order summary")
    end

    context "when order is state: 'payment'" do
      it "should allow visit '/checkout/details'" do
        order.update(state: "payment")
        visit checkout_step_path(:details)
        expect(page).to have_current_path("/checkout/details")
      end
    end
  end

  context "as a logged in user" do
    let(:user) { create(:user) }

    before do
      login_as(user)
      visit checkout_path
    end

    describe "filling out delivery details" do
      before do
        fill_out_details
        fill_out_billing_address
      end

      describe "selecting a pick-up shipping method and submiting the form" do
        before do
          choose free_shipping.name
        end

        it "redirects the user to the Payment Method step" do
          fill_notes("SpEcIaL NoTeS")
          proceed_to_payment
        end
      end

      describe "selecting a delivery method" do
        before do
          choose shipping_with_fee.name
        end

        context "with same shipping and billing address" do
          before do
            check "ship_address_same_as_billing"
          end
          it "does not display the shipping address form" do
            expect(page).not_to have_field "order_ship_address_attributes_address1"
          end

          it "redirects the user to the Payment Method step, when submiting the form" do
            proceed_to_payment
            # asserts whether shipping and billing addresses are the same
            ship_add_id = order.reload.ship_address_id
            bill_add_id = order.reload.bill_address_id
            expect(Spree::Address.where(id: bill_add_id).pluck(:address1) ==
              Spree::Address.where(id: ship_add_id).pluck(:address1)).to be true
          end
        end

        context "with different shipping and billing address" do
          before do
            uncheck "ship_address_same_as_billing"
          end
          it "displays the shipping address form and the option to save it as default" do
            expect(page).to have_field "order_ship_address_attributes_address1"
          end

          it "displays error messages when submitting incomplete billing address" do
            click_button "Next - Payment method"
            expect(page).to have_content "Saving failed, please update the highlighted fields."
            expect(page).to have_field("Address", with: "")
            expect(page).to have_field("City", with: "")
            expect(page).to have_field("Postcode", with: "")
            expect(page).to have_content("can't be blank", count: 3)
          end

          it "fills in shipping details and redirects the user to the Payment Method step,
          when submiting the form" do
            fill_out_shipping_address
            fill_notes("SpEcIaL NoTeS")
            proceed_to_payment
            # asserts whether shipping and billing addresses are the same
            ship_add_id = Spree::Order.first.ship_address_id
            bill_add_id = Spree::Order.first.bill_address_id
            expect(Spree::Address.where(id: bill_add_id).pluck(:address1) ==
             Spree::Address.where(id: ship_add_id).pluck(:address1)).to be false
          end
        end
      end
    end

    describe "not filling out delivery details" do
      before do
        fill_in "Email", with: ""
      end
      it "should display error when fields are empty" do
        click_button "Next - Payment method"
        expect(page).to have_content("Saving failed, please update the highlighted fields")
        expect(page).to have_field("First Name", with: "")
        expect(page).to have_field("Last Name", with: "")
        expect(page).to have_field("Email", with: "")
        expect(page).to have_content("is invalid")
        expect(page).to have_field("Phone number", with: "")
        expect(page).to have_field("Address", with: "")
        expect(page).to have_field("City", with: "")
        expect(page).to have_field("Postcode", with: "")
        expect(page).to have_content("can't be blank", count: 7)
        expect(page).to have_content("Select a shipping method")
      end
    end

    context "with a saved address" do
      let!(:address_state) do
        create(:state, name: "Testville", abbr: "TST", country: DefaultCountry.country )
      end
      let(:saved_address) do
        create(:bill_address, state: address_state, zipcode: "TST01" )
      end

      before do
        user.update_columns bill_address_id: saved_address.id
      end

      it "pre-fills address details" do
        visit checkout_path
        expect(page).to have_select "order_bill_address_attributes_state_id", selected: "Testville"
        expect(page).to have_field "order_bill_address_attributes_zipcode", with: "TST01"
      end
    end

    context "summary step" do
      let(:order) { create(:order_ready_for_confirmation, distributor: distributor) }

      describe "completing the checkout" do
        it "keeps the distributor selected for the current user after completion" do
          visit checkout_step_path(:summary)

          expect(page).to have_content "Shopping @ #{distributor.name}"

          click_on "Complete order"

          expect(page).to have_content "Back To Store"
          expect(order.reload.state).to eq "complete"

          expect(page).to have_content "Shopping @ #{distributor.name}"
        end
      end

      describe "terms and conditions" do
        context "when none are required" do
          it "doesn't show checkbox or links" do
            visit checkout_step_path(:summary)

            within "#checkout" do
              expect(page).to_not have_field "order_accept_terms"
              expect(page).to_not have_link "Terms and Conditions"
              expect(page).to_not have_link "Terms of service"
            end
          end
        end

        context "when distributor has T&Cs" do
          let(:fake_terms_and_conditions_path) { white_logo_path }
          let(:terms_and_conditions_file) {
            Rack::Test::UploadedFile.new(fake_terms_and_conditions_path, "application/pdf")
          }
          let(:terms_url) { order.distributor.terms_and_conditions.url }

          before do
            order.distributor.terms_and_conditions = terms_and_conditions_file
            order.distributor.save
          end

          describe "when customer has not accepted T&Cs before" do
            it "shows a link to the T&Cs and disables checkout button until terms are accepted" do
              visit checkout_step_path(:summary)
              expect(page).to have_link "Terms and Conditions", href: terms_url
              expect(page).to have_field "order_accept_terms", checked: false
            end
          end

          describe "when customer has already accepted T&Cs before" do
            before do
              customer = create(:customer, enterprise: order.distributor, user: user)
              customer.update terms_and_conditions_accepted_at: Time.zone.now
            end

            it "enables checkout button (because T&Cs are accepted by default)" do
              visit checkout_step_path(:summary)
              expect(page).to have_field "order_accept_terms", checked: true
            end

            describe "but afterwards the enterprise has uploaded a new T&Cs file" do
              before { order.distributor.update terms_and_conditions_updated_at: Time.zone.now }

              it "disables checkout button until terms are accepted" do
                visit checkout_step_path(:summary)
                expect(page).to have_field "order_accept_terms", checked: false
              end
            end
          end
        end

        context "when the platform's terms of service have to be accepted" do
          let(:tos_url) { "https://example.org/tos" }

          before do
            allow(Spree::Config).to receive(:shoppers_require_tos).and_return(true)
            allow(Spree::Config).to receive(:footer_tos_url).and_return(tos_url)
          end

          it "shows the terms which need to be accepted" do
            visit checkout_step_path(:summary)

            expect(page).to have_link "Terms of service", href: tos_url
            expect(find_link("Terms of service")[:target]).to eq "_blank"
            expect(page).to have_field "order_accept_terms", checked: false
          end

          context "when the terms have been accepted in the past" do
            before do
              TermsOfServiceFile.create!(
                attachment: File.open(Rails.root.join("public/Terms-of-service.pdf")),
                updated_at: 1.day.ago,
              )
              customer = create(:customer, enterprise: order.distributor, user: user)
              customer.update(terms_and_conditions_accepted_at: Time.zone.now)
            end

            it "remembers the selection" do
              visit checkout_step_path(:summary)

              expect(page).to have_link "Terms of service"
              expect(page).to have_field "order_accept_terms", checked: true
            end
          end
        end

        context "when the seller's terms and the platform's terms have to be accepted" do
          let(:fake_terms_and_conditions_path) { white_logo_path }
          let(:terms_and_conditions_file) {
            Rack::Test::UploadedFile.new(fake_terms_and_conditions_path, "application/pdf")
          }
          let(:tos_url) { "https://example.org/tos" }
          let(:terms_url) { order.distributor.terms_and_conditions.url }

          before do
            order.distributor.terms_and_conditions = terms_and_conditions_file
            order.distributor.save!

            allow(Spree::Config).to receive(:shoppers_require_tos).and_return(true)
            allow(Spree::Config).to receive(:footer_tos_url).and_return(tos_url)
          end

          it "shows links to both terms and all need accepting" do
            visit checkout_step_path(:summary)

            expect(page).to have_link "Terms and Conditions", href: terms_url
            expect(page).to have_link "Terms of service", href: tos_url
            expect(page).to have_field "order_accept_terms", checked: false
          end
        end
      end
    end
  end

  context "when I have an out of stock product in my cart" do
    before do
      variant.update!(on_demand: false, on_hand: 0)
    end

    it "returns me to the cart with an error message" do
      visit checkout_path

      expect(page).not_to have_selector 'closing', text: "Checkout now"
      expect(page).to have_selector 'closing', text: "Your shopping cart"
      expect(page).to have_content "An item in your cart has become unavailable"
    end
  end
end
