# frozen_string_literal: true

require_relative '../../../step/dividend'
require_relative '../../../step/half_pay'

module Engine
  module Game
    module G1873
      module Step
        class Dividend < Engine::Step::Dividend
          DIVIDEND_TYPES = %i[payout half withhold].freeze
          include Engine::Step::HalfPay

          def actions(entity)
            return [] if entity.minor? || entity == @game.mhe
            return [] if entity.company?
            return [] unless total_revenue(entity).positive?

            ACTIONS
          end

          def skip!
            @round.clear_cache!
            revenue = total_revenue(current_entity)
            process_dividend(Action::Dividend.new(
              current_entity,
              kind: revenue.positive? ? 'payout' : 'withhold',
            ))

            current_entity.operating_history[[@game.turn, @round.round_num]] =
              OperatingInfo.new([], @game.actions.last, revenue)
          end

          def total_revenue(entity)
            return @game.mhe_income if entity == @game.mhe
            return 0 - @round.maintenance if routes.empty? && @game.railway?(entity)

            @game.routes_revenue(routes) - @round.maintenance + (entity == @game.qlb ? @game.qlb_bonus : 0)
          end

          def dividend_options(entity)
            revenue = total_revenue(entity)
            dividend_types.map do |type|
              payout = send(type, entity, revenue)
              payout[:divs_to_corporation] = corporation_dividends(entity, payout[:per_share])
              [type, payout.merge(share_price_change(entity, revenue - payout[:corporation]))]
            end.to_h
          end

          def process_dividend(action)
            entity = action.entity
            kind = action.kind.to_sym

            revenue = total_revenue(entity)

            if (revenue + entity.cash).negative?
              @log << "#{entity.name} loses #{@game.format_currency(-revenue)} and cannot pay out of treasury"
              if entity.minor?
                # zero out cash so owner doesn't get anything
                entity.spend(entity.cash, @game.bank) if entity.cash.positive?
                @game.close_mine!(entity)
              else
                @game.insolvent!(entity)
              end
              return
            end

            # assumption: withholding only
            if revenue.negative?
              @log << "#{entity.name} pays #{@game.format_currency(-revenue)} from treasury"
              entity.spend(-revenue, @game.bank)
            end

            payout = dividend_options(entity)[kind]

            entity.operating_history[[@game.turn, @round.round_num]] = OperatingInfo.new(
              routes,
              action,
              revenue
            )

            entity.trains.each { |train| train.operated = true }
            @round.routes = []

            log_run_payout(entity, kind, revenue, action, payout)

            @game.bank.spend(payout[:corporation], entity) if payout[:corporation].positive?

            payout_shares(entity, revenue - payout[:corporation]) if payout[:per_share].positive?

            change_share_price(entity, payout)

            pass!
          end

          # shares in IPO and pool never pay
          def corporation_dividends(_entity, _per_share)
            0
          end

          def share_price_change(entity, revenue = 0)
            return {} if entity.minor?
            return {} if entity == @game.mhe && @game.mhe.trains.any? { |t| t.name == '5T' }

            price = entity.share_price.price
            return { share_direction: :left, share_times: 1 } unless revenue.positive?

            times = [(revenue / price).to_i, 3].min
            if times.positive?
              { share_direction: :right, share_times: times }
            else
              {}
            end
          end

          def payout(entity, revenue)
            return super if entity.corporation?

            amount = revenue / 2
            { corporation: amount, per_share: amount }
          end

          def payout_shares(entity, revenue)
            return super if entity.corporation?

            @log << "#{entity.owner.name} receives #{@game.format_currency(revenue)}"
            @game.bank.spend(revenue, entity.owner)
          end
        end
      end
    end
  end
end
