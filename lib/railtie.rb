module PHP
	class Railtie < Rails::Railtie
		ActionDispatch::Flash::FlashHash.class_eval do
			def to_assoc
				hash = {
					:used => @used.to_a.dup,
					:closed => @closed,
					:flashes => @flashes.dup,
					:now => @now
				}

				hash.to_a
			end

			def from_assoc(assoc)
				hash = Hash[*assoc.map { |v| [v[0].to_sym, v[1]]}.flatten(1)]

				@used = Set.new hash[:used].map(&:to_sym).to_a
				@closed = hash[:closed]
				@flashes = hash[:flashes] ? Hash[*hash[:flashes].map { |k,v| [k.to_sym, v] }.flatten(1)] : {}
				@now = hash[:now]
			end
		end
	end
end