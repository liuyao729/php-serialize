#!/usr/bin/env ruby
# Copyright (c) 2003-2009 Thomas Hurst <tom@hur.st>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# PHP serialize() and unserialize() workalikes
#
# Release History:
#  1.0.0 - 2003-06-02 - First release.
#  1.0.1 - 2003-06-16 - Minor bugfixes.
#  1.0.2 - 2004-09-17 - Switch all {}'s to explicit Hash.new's.
#  1.1.0 - 2009-04-01 - Pass assoc to recursive calls (thanks to Edward Speyer).
#                     - Serialize Symbol like String.
#                     - Add testsuite.
#                     - Instantiate auto-generated Structs properly (thanks
#                       to Philip Hallstrom).
#                     - Unserialize arrays properly in assoc mode.
#                     - Add PHP session support (thanks to TJ Vanderpoel).
#                     - Release as tarball and gem.
#
# See http://www.php.net/serialize and http://www.php.net/unserialize for
# details on the PHP side of all this.

# Adds serialization for Rails objects e.g. Flashes
require 'railtie' if defined? Rails

module PHP
# string = PHP.serialize(mixed var[, bool assoc])
#
# Returns a string representing the argument in a form PHP.unserialize
# and PHP's unserialize() should both be able to load.
#
# Array, Hash, Fixnum, Float, True/FalseClass, NilClass, String and Struct
# are supported; as are objects which support the to_assoc method, which
# returns an array of the form [['attr_name', 'value']..].  Anything else
# will raise a TypeError.
#
# If 'assoc' is specified, Array's who's first element is a two value
# array will be assumed to be an associative array, and will be serialized
# as a PHP associative array rather than a multidimensional array.
	def PHP.serialize(var, assoc = false) # {{{
		s = ''
		case var
			when Array
				s << "a:#{var.size}:{"
				if assoc and var.first.is_a?(Array) and var.first.size == 2
					var.each { |k,v|
						s << PHP.serialize(k, assoc) << PHP.serialize(v, assoc)
					}
				else
					var.each_with_index { |v,i|
						s << "i:#{i};#{PHP.serialize(v, assoc)}"
					}
				end

				s << '}'

			when Hash
				s << "a:#{var.size}:{"
				var.each do |k,v|
					s << "#{PHP.serialize(k, assoc)}#{PHP.serialize(v, assoc)}"
				end
				s << '}'

			when Struct
				n = to_php_serializable_name(var)
				# encode as Object with same name
				s << "O:#{n.length}:\"#{n}\":#{var.members.length}:{"
				var.members.each do |member|
					s << "#{PHP.serialize(member, assoc)}#{PHP.serialize(var[member], assoc)}"
				end
				s << '}'

			when String, Symbol
				s << "s:#{var.to_s.bytesize}:\"#{var.to_s}\";"

			when Fixnum # PHP doesn't have bignums
				s << "i:#{var};"

			when Float
				s << "d:#{var};"

			when NilClass
				s << 'N;'

			when FalseClass, TrueClass
				s << "b:#{var ? 1 :0};"

			else
				if var.respond_to?(:to_assoc)
					n = to_php_serializable_name(var)
					v = var.to_assoc
					# encode as Object with same name
					s << "O:#{n.length}:\"#{n}\":#{v.length}:{"
					v.each do |k,v|
						s << "#{PHP.serialize(k.to_s, assoc)}#{PHP.serialize(v, assoc)}"
					end
					s << '}'
				else
					raise TypeError, "Unable to serialize type #{var.class}"
				end
		end

		s
	end # }}}

# string = PHP.serialize_session(mixed var[, bool assoc])
#
# Like PHP.serialize, but only accepts a Hash or associative Array as the root
# type.  The results are returned in PHP session format.
	def PHP.serialize_session(var, assoc = false) # {{{
		s = ''
		case var
		when Hash
			var.each do |key,value|
				if key.to_s =~ /\|/
					raise IndexError, "Top level names may not contain pipes"
				end
				s << "#{key}|#{PHP.serialize(value, assoc)}"
			end
		when Array
			var.each do |x|
				case x
				when Array
					if x.size == 2
						s << "#{x[0]}|#{PHP.serialize(x[1])}"
					else
						raise TypeError, "Array is not associative"
					end
				end
			end
		else
			raise TypeError, "Unable to serialize sessions with top level types other than Hash and associative Array"
		end
		s
	end # }}}

# mixed = PHP.unserialize(string serialized, [bool assoc])
#
# Returns an object containing the reconstituted data from serialized.
#
# If a PHP array (associative; like an ordered hash) is encountered, it
# scans the keys; if they're all incrementing integers counting from 0,
# it's unserialized as an Array, otherwise it's unserialized as a Hash.
# Note: this will lose ordering.  To avoid this, specify assoc=true,
# and it will be unserialized as an associative array: [[key,value],...]
#
# If it's not found in the current constant namespace,
# a new Struct(classname) is generated, with the arguments
# for .new specified in the same order PHP provided; since PHP uses hashes
# to represent attributes, this should be the same order they're specified
# in PHP, but this is untested.
#
# each serialized attribute is sent to the new object using the respective
# {attribute}=() method; you'll get a NameError if the method doesn't exist.
#
# Array, Hash, Fixnum, Float, True/FalseClass, NilClass and String should
# be returned identically (i.e. foo == PHP.unserialize(PHP.serialize(foo))
# for these types); Struct should be too, provided it's in the namespace
# Module.const_get within unserialize() can see, or you gave it the same
# name in the Struct.new(<structname>).
#
# Note: StringIO is required for unserialize(); it's loaded as needed
	def PHP.unserialize(string, assoc = false) # {{{
		require 'stringio'
		string = StringIO.new(string)
		def string.read_until(char)
			val = ''
			while (c = self.read(1)) != char
				val << c
			end
			val
		end

		if string.string =~ /^([\w\.]+)\|/ # session_name|serialized_data
			ret = Hash.new
			loop do
				if string.string[string.pos, 32] =~ /^([\w\.]+)\|/
					string.pos += $&.size
					ret[$1] = PHP.do_unserialize(string, assoc)
				else
					break
				end
			end
			ret
		else
			PHP.do_unserialize(string, assoc)
		end
	end

private
	def PHP.do_unserialize(string, assoc)
		val = nil
		# determine a type
		type = string.read(2)[0,1]
		case type
			when 'a' # associative array, a:length:{[index][value]...}
				count = string.read_until('{').to_i
				val = vals = Array.new
				count.times do |i|
					vals << [do_unserialize(string, assoc), do_unserialize(string, assoc)]
				end
				string.read(1) # skip the ending }

				# now, we have an associative array, let's clean it up a bit...
				# arrays have all numeric indexes, in order; otherwise we assume a hash
				array = true
				i = 0
				vals.each do |key,value|
					if key != i # wrong index -> assume hash
						array = false
						break
					end
					i += 1
				end

				if array
					vals.collect! do |key,value|
						value
					end
				else
					if assoc
						val = vals.map {|v| v }
					else
						val = Hash.new
						vals.each do |key,value|
							val[key] = value
						end
					end
				end

			when 'O' # object, O:length:"class":length:{[attribute][value]...}
				# class name (lowercase in PHP, grr)
				len = string.read_until(':').to_i + 3 # quotes, seperator
				klass = string.read(len)[1...-2].intern # read it, kill useless quotes

				# read the attributes
				attrs = []
				len = string.read_until('{').to_i

				len.times do
					attrs << [do_unserialize(string, assoc), do_unserialize(string, assoc)]
				end
				string.read(1)

				val = nil
				begin
					val = from_php_serializable_name(klass).new
				rescue NameError # Nope; make a new Struct
					val = Struct.new(klass.to_s.capitalize, *attrs.collect { |v| v[0].to_s })
					val = val.new
				end

				if val.respond_to?(:from_assoc)
					val.from_assoc(attrs)
				else
					attrs.each do |attr,v|
						val.__send__("#{attr}=", v)
					end
				end

			when 's' # string, s:length:"data";
				len = string.read_until(':').to_i + 3 # quotes, separator
				val = string.read(len)[1...-2] # read it, kill useless quotes

			when 'i' # integer, i:123
				val = string.read_until(';').to_i

			when 'd' # double (float), d:1.23
				val = string.read_until(';').to_f

			when 'N' # NULL, N;
				val = nil

			when 'b' # bool, b:0 or 1
				val = (string.read(2)[0] == ?1 ? true : false)

			else
				raise TypeError, "Unable to unserialize type '#{type}'"
		end

		val
	end # }}}

	# Takes value of type TestModule::TestObject and returns string 'test_module__test_object'
	def self.to_php_serializable_name(value)
		value.class.name.gsub('::', '__').gsub(/([a-z\d])([A-Z])/,'\1_\2').downcase
	end

	# Takes string 'test_module__test_object' and returns constant TestModule::TestObject
	def self.from_php_serializable_name(name)
		constantize(camelize(name.to_s.gsub('__', '/')))
	end

	# Tries to find a constant with the name specified in the argument string:
	# (based on same from ActiveSupport)
	def self.constantize(camel_cased_word)
		names = camel_cased_word.to_s.split('::')
		names.shift if names.empty? || names.first.empty?

		constant = Object
		names.each do |name|
			constant = constant.const_defined?(name) ? constant.const_get(name) : constant.const_missing(name)
		end
		constant
	end

	# Converts strings to UpperCamelCase
	# (based on same from ActiveSupport)
	def self.camelize(term, uppercase_first_letter = true)
		string = term.to_s
		if uppercase_first_letter
			string = string.sub(/^[a-z\d]*/) { $&.capitalize }
		end
		string.gsub(/(?:_|(\/))([a-z\d]*)/i) { "#{$1}#{$2.capitalize}" }.gsub('/', '::')
	end
end

