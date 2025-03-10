# frozen_string_literal: true

require_relative '../../../step/track'

module Engine
  module Game
    module G1873
      module Step
        class Track < Engine::Step::Track
          def round_state
            {
              non_double_tile: false,
              num_laid_track: 0,
              laid_hexes: [],
            }
          end

          def setup
            @round.num_laid_track = 0
            @round.non_double_tile = false
            @round.laid_hexes = []
          end

          def actions(entity)
            return [] unless entity == current_entity
            return [] if @game.public_mine?(entity) || @game.connected_mine?(entity) || entity == @game.mhe
            return [] if entity.company? || !can_lay_tile?(entity)

            ACTIONS
          end

          def process_pass(action)
            entity = action.entity
            if @game.concession_incomplete?(entity)
              # can't pass if concession is incomplete
              raise GameError, 'Must complete concession route'
            end

            super
          end

          def process_lay_tile(action)
            entity = action.entity

            lay_tile_action(action)

            # force recalculation of mine connections
            @game.mine_graph.clear if entity.corporation?

            # update token/route and diesel graphs
            @game.graph.clear
            @game.diesel_graph.clear

            # check to see if concession is complete
            if @game.concession_incomplete?(entity) && @game.concession_route_done?(entity)
              @game.concession_complete!(entity)
              @round.num_laid_track = 2 # prevent any more tiles this turn
            end

            @game.free_tile_reservation!(action.hex, action.tile)

            pass! unless can_lay_tile?(action.entity)
          end

          def skip!
            if !@acted && current_entity && !@game.public_mine?(current_entity) && current_entity != @game.mhe
              log_skip(current_entity)
            end
            pass!
          end

          def can_lay_tile?(entity)
            return true if abilities(entity, time: type, passive_ok: false)
            return false if entity.minor? && @round.num_laid_track.positive?

            # deal with case where concession route happened to be completed
            # before railroad even got to it's first OR
            if @game.concession_incomplete?(entity) && @game.concession_route_done?(entity)
              @game.concession_complete!(entity)
              pay_full_concession_cost!(entity)
            end

            return false if !@game.concession_incomplete?(entity) && @round.non_double_tile

            action = get_tile_lay(entity)
            return false unless action

            (entity.minor? || !entity.tokens.empty?) && (buying_power(entity) >= action[:cost]) &&
              (action[:lay] || action[:upgrade])
          end

          def get_tile_lay(entity)
            return @game.tile_lays(entity)[0]&.clone if @game.concession_incomplete?(entity)

            action = @game.tile_lays(entity)[@round.num_laid_track]&.clone
            return unless action

            action[:lay] = !@round.non_double_tile if action[:lay] == :double_lay
            action[:upgrade] = !@round.non_double_tile if action[:upgrade] == :double_lay
            action[:cost] = action[:cost] || 0
            action
          end

          def lay_tile_action(action, entity: nil, spender: nil)
            tile = action.tile
            tile_lay = get_tile_lay(action.entity)

            if !@game.double_lay?(tile) && @round.num_laid_track.positive?
              raise GameError, 'Must lay yellow or green with 2 unconnected track sections'
            end

            lay_tile(action, extra_cost: tile_lay[:cost], entity: entity, spender: spender)
            @round.num_laid_track += 1
            @round.non_double_tile = true unless @game.double_lay?(tile)
            @round.laid_hexes << action.hex
          end

          def potential_tiles(entity, hex)
            return super unless @game.concession_incomplete?(entity)

            if !@game.concession_tile(hex)
              # can only lay in concession hexes
              []
            elsif @game.reserved_tiles[hex.id][:entity] == entity.name
              # can only lay reserved tile for this hex
              [@game.reserved_tiles[hex.id][:tile]]
            else
              # can only lay concession tile of this hex
              [@game.tiles.find { |t| t.name == @game.concession_tile(hex)[:tile] }]
            end
          end

          def check_track_restrictions!(entity, old_tile, new_tile)
            return if @game.loading || !entity.operator?

            graph = @game.graph_for_entity(entity)
            old_paths = old_tile.paths

            # tile is illegal if there exists a path on the new tile that is:
            # A. Not reachable, AND
            # B. Not on the old tile, AND
            # C. Not state RR track
            new_tile.paths.each do |np|
              if !graph.connected_paths(entity)[np] && np.track != :broad && !old_paths.find { |path| np <= path }
                raise GameError, 'Must use all new track'
              end
            end
          end

          # yes, I'm hijacking this a little but I need a way to see if a tile needs to be
          # reserved and the owner reimbursed for working on another company's concession route
          # and the concession company having to pay for previously laid tiles
          def pay_tile_cost!(entity, tile, rotation, hex, spender, cost, _extra_cost)
            reimburse = false
            ch = @game.concession_tile(tile.hex)
            ch_entity = @game.corporation_by_id(ch[:entity]) if ch
            if ch && entity.name != ch[:entity] && (tile.exits & ch[:exits]).size == ch[:exits].size
              @log << "Laying tile finishes concession track in #{hex.id}"
              reimburse = true
            elsif ch && entity.name != ch[:entity] && (tile.exits & ch[:exits]).size != ch[:exits].size
              res_tile = @game.reserve_tile!(hex, tile)
              raise GameError, 'Tile prevents concession from being completed' unless res_tile

              reimburse = true
            elsif ch && (tile.exits & ch[:exits]).size != ch[:exits].size
              raise GameError, 'Tile must complete concession route'
            elsif ch && cost != ch[:cost]
              cost += ch[:cost]
              @log << "#{entity.owner} must pay for previously reimbused tile cost"\
                "of #{@game.format_currency(ch[:cost])}"
            end

            @game.advance_concession_phase!(ch_entity) if reimburse && hex.id != 'D15'

            super

            return unless reimburse && cost.positive?

            @game.bank.spend(cost, entity.owner)
            @log << "#{entity.owner.name} is reimbursed for building the tile"
          end

          def pay_full_concession_cost!(entity)
            total_cost = @game.concession_tile_hexes(entity).sum { |h| @game.concession_tile_hex(h)[:cost] }
            return unless total_cost.positive?

            @log << "#{entity.name} had entire concession route previously built"
            @log << "#{entity.name} pays entire concession cost of #{@game.format_currency(total_cost)}"
            entity.spend(total_cost, @game.bank)
          end
        end
      end
    end
  end
end
