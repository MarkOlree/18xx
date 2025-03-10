# frozen_string_literal: true

require_relative '../../../step/route'

module Engine
  module Game
    module G1873
      module Step
        class Route < Engine::Step::Route
          def actions(entity)
            return [] if entity.minor? || @game.public_mine?(entity) || entity == @game.mhe
            return [] if entity.company?

            super
          end

          def skip!
            @game.update_tokens(current_entity, [])
            return super if !@game.any_mine?(current_entity) && current_entity != @game.mhe

            if @game.any_mine?(current_entity)
              @game.update_mine_revenue(@round, current_entity) if @round.routes.empty?
              @round.clear_cache!
            end

            pass!
          end

          def process_run_routes(action)
            super

            entity = action.entity
            routes = action.routes

            routes.each do |r|
              @game.use_pool_diesel(r.train, entity) if @game.diesel?(r.train)
            end
            @game.free_pool_diesels(entity)

            maintenance = @game.maintenance_costs(entity)
            @round.maintenance = maintenance
            @log << "#{entity.name} owes #{@game.format_currency(maintenance)} for maintenance" if maintenance.positive?

            @game.update_tokens(entity, action.routes)
          end

          def train_name(_entity, train)
            @game.train_name(train)
          end

          def round_state
            {
              routes: [],
              maintenance: 0,
            }
          end
        end
      end
    end
  end
end
