#--
# Copyright 2013 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#++

require 'openshift-origin-node/utils/node_logger'
require 'openshift-origin-common/utils/path_utils'

module OpenShift
  module Runtime
    module Utils
      # Class represents the OpenShift/Ruby analogy of C environ(7)
      class Environ
        # Load the combined cartridge environments for a gear
        # @param [String]        gear_dir             Home directory of the gear
        # @param [Array<String>] cartridge_dirs       Home directories of cartridges,
        #                                             loaded last to override other settings.
        # @return [Hash<String,String>] hash[Environment Variable] = Value
        def self.for_gear(gear_dir, *dirs)
          env = load('/etc/openshift/env')

          env.merge!(load(
                         PathUtils.join(gear_dir, '.env'),
                         PathUtils.join(gear_dir, '*', 'env')))

          # Load environment variables under subdirectories in ~/.env
          Dir[PathUtils.join(gear_dir, '.env', '*')].each do |entry|
            next if entry.end_with?('user_vars')
            env.merge!(load(entry)) if File.directory?(entry)
          end


          # If we have a primary cartridge make sure it's the last loaded in the environment
          primary = if env.has_key? 'OPENSHIFT_PRIMARY_CARTRIDGE_DIR'
                      dirs.delete env['OPENSHIFT_PRIMARY_CARTRIDGE_DIR']
                      dirs << env['OPENSHIFT_PRIMARY_CARTRIDGE_DIR']

                      File.basename(env['OPENSHIFT_PRIMARY_CARTRIDGE_DIR']).upcase
                    end

          dirs.each_with_object(env) { |d, e| e.merge!(load(PathUtils.join(d, 'env'))) }

          env['PATH'] = collect_elements_from(env, 'PATH', primary).join(':')
          env['LD_LIBRARY_PATH'] = collect_elements_from(env, 'LD_LIBRARY_PATH', primary).join(':')

          user_vars = PathUtils.join(gear_dir, '.env', 'user_vars')
          env.merge!(load(user_vars)) if File.exist?(user_vars)
          env
        end

        def self.collect_elements_from(env, var_name, primary)
          system_path = env[var_name]
          primary_path = "OPENSHIFT_#{primary}_#{var_name}_ELEMENT"

          # Prevent conflict with the PATH variable
          #
          if var_name == 'PATH'
            env = env.clone
            env.delete_if { |name, _| name =~ /_LD_LIBRARY_PATH_ELEMENT$/}
          end

          elements = env.keys.find_all { |name|
            name =~ /^OPENSHIFT_.*_#{var_name}_ELEMENT/ and name != primary_path
          }.each_with_object([]) { |s, p| p << env[s] }

          # For PATH we want to add the primary gear path to beggining of final
          # gear PATH, for other (like LD_LIBRARY_PATH), plugin paths takes
          # precedence.
          #
          if env.has_key?(primary_path)
            var_name == 'PATH' ? elements.unshift(env[primary_path]) : elements.push(env[primary_path])
          end

          elements << system_path if system_path
          elements
        end

        # Read a Gear's + n number cartridge environment variables into a environ(7) hash
        # @param [String]               env_dir of gear to be read
        # @return [Hash<String,String>] environment variable name: value
        def self.load(*dirs)
          dirs.each_with_object({}) do |env_dir, env|
            # add wildcard for globbing if needed
            env_dir += '/*' if not env_dir.end_with? '*'

            # Find, read and load environment variables into a hash
            Dir[env_dir].each do |file|
              next if file.end_with? '.erb'
              next unless File.file? file

              begin
                contents = IO.read(file).chomp

                if contents.start_with? 'export '
                  index           = contents.index('=')
                  parsed_contents = contents[(index + 1)..-1]
                  parsed_contents.gsub!(/\A["']|["']\Z/, '')
                  env[File.basename(file)] = parsed_contents
                else
                  env[File.basename(file)] = contents
                end
              rescue => e
                msg = "Failed to process: #{file}"
                unless contents.nil?
                  msg << " [#{contents}]"
                end
                msg << ': '
                msg << (
                case e
                  when SystemCallError
                    # This catches filesystem level errors
                    # We split the message because it contains the filename
                    e.message.split(' - ').first
                  else
                    e.message
                end
                )
                NodeLogger.logger.info(msg)
              end
            end
          end
        end

      end
    end
  end
end
