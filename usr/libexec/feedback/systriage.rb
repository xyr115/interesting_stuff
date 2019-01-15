#!/usr/bin/ruby
require "rubygems"
require "optparse"
require "date"
require "time"
require "rational"
require "json"

# CONSTANTS
KILOBYTE = 1024
MEGABYTE = KILOBYTE * 1024
GIGABYTE = MEGABYTE * 1024
TERABYTE = GIGABYTE * 1024

# Not really true, but we only want to approximate and won't use this for reliable calendrical calculations
SECONDS_IN_DAY = 86400

FREE_MEMORY_THRESHOLD = 50 * MEGABYTE
DISKIO_THRESHOLD      = 10

SYSTRIAGE_VERSION = "1.5"

SYSTEMSTATS_PATH = "/usr/sbin/systemstats"
SPINDUMP_PATH    = "/usr/sbin/spindump"

SYSDIAGNOSE_ENCODING = "r:utf-8"

HSEP = " | "
VSEP = "-"

#This determines whether or not the process should add in escape colors for terminal output
if STDOUT.tty?
    BOLD    = "\e[1m"
    RED     = "\e[31m"
    GREEN   = "\e[32m"
    DEFAULT = "\e[0m"
else
    BOLD    = ""
    RED     = ""
    GREEN   = ""
    DEFAULT = ""
end

################################################################################
########## Support for Mini Mode ###############################################
################################################################################

class MiniModeResults
    attr_accessor :prefix, :dict

    def initialize(prefix)
        @prefix = prefix
        @dict = Hash.new
    end
    
    def add(key, value)
        dict["#{prefix}_#{key}"] = value
    end
    
    def pretty_generate()
        puts JSON.pretty_generate(dict)
    end
end

################################################################################
########## Safety Utilities ####################################################
################################################################################

module ErrorLog
    @errors = {}

    def ErrorLog.report(str)
        if @errors[str] == nil
            @errors[str] = 1
        else
            @errors[str] += 1
        end
    end

    def ErrorLog.exit_verbose(exit_str)
        $stderr.puts exit_str
        if not @errors.empty?
            header = "#{"Number of errors".rjust(20)} : Error Tag"
            $stderr.puts(header)
            $stderr.puts(VSEP * (header.length))
            @errors.each{|str,count| $stderr.puts "#{count.to_s.rjust(20)} : #{str}\n"}
        end
        exit
    end
end

module SafeParse
    def SafeParse.to_string(tag, str)
        if (str == nil)
            ErrorLog.report("Parse error: #{tag}: argument nil")
            return ""
        else
            return str.strip()
        end
    end

    def SafeParse.encode_string(tag, str)
        if (str == nil)
            ErrorLog.report("Parse error: Encoding/#{tag}: argument nil")
            return ""
        else
            str.encode!(str.encoding, "binary", :invalid => :replace, :undef => :replace)
            return str
        end
    end

    def SafeParse.to_int(tag, str)
        if str == nil
            ErrorLog.report("Parse error: #{tag}: argument nil")
            return 0
        end

        if str.strip =~ /^(\+|-|--)?(\d+)$/
            x = $2.to_i()
            x *= -1 if $1 == "-" or $1 == "--"
            return x
        else
            ErrorLog.report("Parse error: #{tag}")
            return 0
        end
    end

    def SafeParse.to_pid(tag, str)
        if str == nil
            ErrorLog.report("Parse error: #{tag}: argument nil")
            return 0
        end

        if str.strip =~ /^(\d+)-?$/
            x = $1.to_i()
            return x
        else
        ErrorLog.report("Parse error: #{tag}")
            return 0
        end
    end

    def SafeParse.to_float(tag, str)
        if str == nil
            ErrorLog.report("Parse error: #{tag}: argument nil")
            return 0.0
        end

        opt_tail = /\.\d+/
        if str.strip =~ /^(\+|-|--)?(\d+#{opt_tail}?)$/
            x = $2.to_f()
            x *= -1.0 if $1 == "-" or $1 == "--"
            return x
        else
            ErrorLog.report("Parse error: #{tag}")
            return 0.0
        end
    end

    def SafeParse.to_byte(tag, str)
        if str == nil
            ErrorLog.report("Parse error: #{tag}: argument nil")
            return 0
        end

        if str.strip =~ /^(\+|-|--)?(\d+)(B|K|M|G|T)$/
            base = $2.to_i
            mult = $3
            base *= -1 if $1 == "-" or $1 == "--"

            case mult
                when "T"
                    return base * TERABYTE
                when "G"
                    return base * GIGABYTE
                when "M"
                    return base * MEGABYTE
                when "K"
                    return base * KILOBYTE
                when "B"
                    return base
            end
        else
            ErrorLog.report("Parse error: #{tag}")
            return 0
        end
    end

    def SafeParse.byte_to_string(bytes)
        if (bytes > TERABYTE * 10)
            return ((bytes / TERABYTE).to_s + "T")
        elsif (bytes > GIGABYTE * 10)
            return ((bytes / GIGABYTE).to_s + "G")
        elsif (bytes > MEGABYTE * 10)
            return ((bytes / MEGABYTE).to_s + "M")
        elsif (bytes > KILOBYTE * 10)
            return ((bytes / KILOBYTE).to_s + "K")
        else
            return (bytes.to_s + "B")
        end
    end
    
    def SafeParse.float_to_string(f)
        return '%.2f' % f
    end

    def SafeParse.float_to_string_with_precision(f, n)
        return "%.#{n}f" % f
    end

    def SafeParse.parse_time(tag, str, format)
        if str == nil
            ErrorLog.report("Parse error: #{tag}: argument nil")
            return nil
        end

        time = nil
        begin
            time = DateTime.strptime(str, format)
        rescue
            ErrorLog.report("Parse error: #{tag}: does not match time format #{format}, raised exception")
        end
        
        if time == nil
            ErrorLog.report("Parse error: #{tag}: does not match time format #{format}, soft failure")
        end
        
        return time
    end

    def SafeParse.time_to_qstr(str, format)
        return "\"#{str.strftime(format)}\""
    end
end


################################################################################
########## Memory Tasks ########################################################
################################################################################

module Allmemory
    def Allmemory.print_summary(path, top_list)
        puts "\nProcess per-region residency:\n"

        pid_list  = []
        top_list.each{|x| pid_list << x.pid}

        file = File.open(path, SYSDIAGNOSE_ENCODING)
        printing_process = false

        file.each{|line|
            line = SafeParse.encode_string("Allmemory/line", line)
            header1 = "\t   Process Name [ PID]" + " "*4 + "Architecture" + " "*4 + "PrivateRes/NoSpec/NoVolatile" + " "*4 + "Copied" + " "*5 + "Dirty   Swapped" + " "*2 + "Shared/NoSpec"
            header2 = "\t   ===================" + " "*4 + VSEP*12 + " "*4 + VSEP*28 + " "*3 + VSEP*8 + " "*3 + VSEP*7 + " "*2 + VSEP*7 + " "*2 + VSEP*13

            if line =~ /\[([\s\d]*)\]:\s+[0-9]*-bit/
                pid = $1.to_i

                if pid_list.include?(pid)
                    puts ""
                    puts header1
                    puts header2
                    printing_process = true
                end
            end

            if line =~ /^\s+$/
                printing_process = false
            end

            if printing_process
                line[0..20] = ""
                puts line
            end
        }

        file.close()
        return
    end
end


module Heap
    def Heap.parse(path, processes)
        file = File.open(path, SYSDIAGNOSE_ENCODING)
        pid  = 0

        pid_line = file.gets()
        pid_line = SafeParse.encode_string("Heap/line", pid_line)
        if pid_line != nil and pid_line =~ /^Process\s(\d+):/
                pid = $1.to_i()
        else
            ErrorLog.report("Heap: no pid recorded in #{path}")
            file.close()
            return
        end

        execname = "N/A"
        if (processes != nil)
            if (processes[pid] != nil)
                execname = processes[pid]
            end
        end

        puts "Process: #{execname}[#{pid}]"
        puts "#{"Zone".rjust(27)} #{"Nodes Malloced".rjust(16)} #{"Bytes".rjust(7)}"
        puts VSEP*27 + " "*3  + VSEP*14 + " "*3 + VSEP*24

        file.each{|line|
            line = SafeParse.encode_string("Heap/line", line)
            case line
                    #salzman's handy regex
                when /^Zone (.*)_.* ([\d]*) nodes malloced for (\d+[GMK]?)B (.*); largest unused: .*$/
                    puts "#{($1+":").rjust(27)} #{$2.rjust(16)} #{$3.rjust(8)} #{$4.rjust(17)}"
                when /All zones: .*B\n$/
                    puts "\n" + line
            end
        }
        
        file.close()
        return
    end

    # print_summary: string * Hash (int, string) -> unit
    def Heap.print_summary(path, processes)
        if File.exists?("#{path}/heap.txt")
            parse("#{path}/heap.txt", processes)
        end
        
        Dir.foreach(path){|filename|
            filename = SafeParse.encode_string("Heap/fileName", filename)
            if filename =~ /heap-\d+\.txt/
                parse("#{path}/#{filename}", processes)
            end
        }

        return
    end
end


module Leaks
    def Leaks.parse(path)
        file = File.open(path, SYSDIAGNOSE_ENCODING)
        pid  = 0
        execname = ""

        pid_line = file.gets()
        pid_line = SafeParse.encode_string("Leaks/line", pid_line)
        if pid_line != nil and pid_line =~ /^Process:\s+(\S+)\s\[(\d+)\]/
            pid      = $2
            execname = $1
        else
            ErrorLog.report("Leaks: no pid recorded in #{path}")
            file.close()
            return
        end

        file.each{|line|
            line = SafeParse.encode_string("Leaks/line", line)
            if line =~ /^Process #{pid}: (.* bytes\.)/
                leak_line = $1
                puts "#{execname} [#{pid}] had #{leak_line}\n"
            end
        }

        file.close()
        return
    end

    # print_summary: string * Hash (int, string) -> unit
    def Leaks.print_summary(path)
        if File.exists?("#{path}/leaks.txt")
            parse("#{path}/leaks.txt")
        end
        
        Dir.foreach(path){|filename|
            filename = SafeParse.encode_string("Leaks/fileName", filename)
            if filename =~ /leaks-\d+\.txt/
                parse("#{path}/#{filename}")
            end
        }
        
        return
    end
end

################################################################################
########## Power ###############################################################
################################################################################

module PowerUsage
    LEFT_WIDTH = 24
    RIGHT_WIDTH = 12
    # Desc: Class to hold various pieces of information from summary section
    #       of powermetrics.txt
    
    class PowerMetricsState
        attr_accessor   :plugged_in,
        :percent_charge_of_design,
        :max_capacity_in_mAh,
        :remaining_capacity,
        :percent_charge_remaining,
        :cycle_count,
        :backlight_level,
        :interrupts,
        :supported_processor,
        :component,
        :thermal_pressure

        def initialize
            @backlight_level = "Information Unavailable"
            @max_capacity_in_mAh = 0
            @cycle_count = 0
            @interrupts = ["Information Unavailable"]
            @plugged_in = "Information unavailable"
            @percent_charge_of_design = 0.0
            @percent_charge_remaining = 0.0
            @remaining_capacity = 0
            @supported_processor = false
            @component = Hash.new
            @thermal_pressure = "Information Unavailable"
        end
    end
    
    # Desc: Class to hold information on P-State and C-State residency
    #       of CPU (Cores 0 & 1, Package)
    
    class ComponentPowerStats
        attr_accessor   :component_name, :cstates_map, :frequency, :total_cstate_res
        
        def initialize(name)
            @component_name = name
            @frequency = "" # FIXME: parse into a float of reasonable dimension for analysis
            @total_cstate_res = 0.0
            @cstates_map = Hash.new
        end
        #Review: use vsep/hsep :TBD
        def print_cstate_residency_header()
            header = "C-state".rjust(PowerUsage::LEFT_WIDTH) + HSEP + "%Residency".rjust(PowerUsage::RIGHT_WIDTH)
            puts header
            puts VSEP * header.length
        end
        
        def print_cstate_residency()
            sorted_keys = cstates_map.keys.sort
            sorted_keys.each { |key|
                puts key.to_s.rjust(PowerUsage::LEFT_WIDTH) + HSEP + SafeParse.float_to_string(cstates_map[key]).rjust(PowerUsage::RIGHT_WIDTH)
            }
            total_str = "Total".rjust(PowerUsage::LEFT_WIDTH) + HSEP + SafeParse.float_to_string(total_cstate_res).rjust(PowerUsage::RIGHT_WIDTH)
            puts VSEP * total_str.length
            puts total_str
        end
        
        def mini(output_dict)
            sorted_keys = cstates_map.keys.sort
            lowest_state = 0
            lowest_residency = 0.0
            sorted_keys.each { |key|
                temp = cstates_map[key]
                if temp > 0.0
                    lowest_state = key
                    lowest_residency = temp
                end
            }
            
            component_name_safe = component_name.gsub(/\s+/, "_")
            output_dict.add("lowest_cstate_#{component_name_safe}", lowest_state)
            output_dict.add("lowest_cstate_res_#{component_name_safe}", lowest_residency)
            output_dict.add("total_cstate_res_#{component_name_safe}", total_cstate_res)
        end
    end
    
    
    #delimiters for different sections in powermetrics.txt
    
    SECTION_SUMMARY                     = "*** Summary system activity"
    SUBSECTION_BATTERY_BACKLIGHT        = "Battery and backlight usage"
    SUBSECTION_INTERRUPT_DISTRIBUTION   = "Interrupt distribution"
    SUBSECTION_PROCESSOR_USAGE          = "Processor usage"
    SUBSECTION_GPU_USAGE                = "GPU usage"
    SUBSECTION_THERMAL_PRESSURE         = "Thermal pressure"
    SUBSECTIONS_OF_INTEREST = [SUBSECTION_BATTERY_BACKLIGHT, SUBSECTION_INTERRUPT_DISTRIBUTION, SUBSECTION_PROCESSOR_USAGE, SUBSECTION_GPU_USAGE, SUBSECTION_THERMAL_PRESSURE]
    
    def PowerUsage.parse_thermal_pressure(powermetrics, lines)
        lines.each { |line|
            if line =~ /Current pressure level:\s+(\S+.+)*/
                powermetrics.thermal_pressure = SafeParse.to_string("Powermetrics/thermalPressure", $1.strip)
                break
            end
        }
    end
    
    def PowerUsage.print_thermal_info(powermetrics)
        puts "Thermal Pressure Level".ljust(PowerUsage::LEFT_WIDTH) + HSEP + powermetrics.thermal_pressure.rjust(PowerUsage::RIGHT_WIDTH)
    end

    def PowerUsage.mini_thermal_info(powermetrics, output_dict)
        output_dict.add("thermal_pressure_level", powermetrics.thermal_pressure)
    end

    def PowerUsage.parse_file(powermetrics, path, detailed, content_map)
        skip = true
        file = File.open(path,SYSDIAGNOSE_ENCODING)
        subsection_regex = /^\*\*\*\*\s+(.+)\s+\*\*\*\*/
        subsection_name     = nil
        subsection_contents = nil
        file.each { |line|
            line = SafeParse.to_string("PowerMetrics/lineEncoding", line)
            #PowerMertics output has 10 samples followed by their summary at the end.
            #Discard samples until summary has been reached
            if (skip == true)
                if (line.start_with?(PowerUsage::SECTION_SUMMARY))
                    skip = false
                end
                next
            else
                if line.strip == ""
                    next
                end

                if line =~ subsection_regex
                    new_subsection_name = $1
                    if subsection_name != nil
                        content_map[subsection_name] = subsection_contents
                        subsection_name     = nil
                        subsection_contents = nil
                    end
                    
                    if PowerUsage::SUBSECTIONS_OF_INTEREST.include?(new_subsection_name)
                        subsection_name     = new_subsection_name
                        subsection_contents = Array.new
                    end
                elsif subsection_contents != nil
                    subsection_contents.push line
                end
            end
        }
    end
    
    def PowerUsage.parse_battery_info(powermetrics, lines)
        #Example: Battery: delta: 0 mAh, discharge rate: 0 mAh/minute, cycle count 16, capacity: 7239 mAh (101.245% of design), charge remaining: 6680 mAh, plugged in: no
        plus_or_minus = /\+|-/
        float_tail = /\.\d+/
        battery_regex = /Battery: delta: #{plus_or_minus}?\d+ mAh, discharge rate: #{plus_or_minus}?\d+#{float_tail}? mAh\/minute, cycle count (\d+), capacity: (\d+) mAh \((\d+#{float_tail}?)% of design\), charge remaining: (\d+) mAh, plugged #{"in"}: (\w*)/
        # Example: Backlight level: 167 (range 0-1024)
        backlight_regex = /Backlight level: (\d+) .*/
        lines.each { |line|
            case line
                when backlight_regex
                    powermetrics.backlight_level = SafeParse.to_int("PowerUsage/Backlight", $1)
                when battery_regex
                    powermetrics.cycle_count = SafeParse.to_int("PowerUsage/CycleCount", $1)
                    powermetrics.max_capacity_in_mAh = SafeParse.to_int("PowerUsage/BatteryChargeMax", $2)
                    powermetrics.percent_charge_of_design = SafeParse.to_float("PowerUsage/BatteryPercentOfDesignCapacity", $3)
                    powermetrics.remaining_capacity = SafeParse.to_int("PowerUsage/BatteryChargeRemaining", $4)
                    powermetrics.plugged_in = SafeParse.to_string("PowerUsage/PluggedIn", $5)
                    powermetrics.percent_charge_remaining = powermetrics.remaining_capacity * 100 / powermetrics.max_capacity_in_mAh
            end
        }
    end
    
    def PowerUsage.parse_cstate_residency(powermetrics, line, component_name)
        if(powermetrics.component[component_name] == nil)
            powermetrics.component[component_name] = ComponentPowerStats.new(component_name)
        end
        #Package 0 C-state residency: 76.79% (C2: 12.28% C3: 0.77% C6: 0.00% C7: 63.75% C8: 0.00% C9: 0.00% C10: 0.00% )
        if (line =~ /#{component_name} C-state residency: (\d+.\d+)% \((.*)\)/)
            total = SafeParse.to_float("Total C-state residency", $1)
            powermetrics.component[component_name].total_cstate_res = total
            fields = $2.strip.split("%")
            fields.each { |field|
                field = field.strip
                temp = field.split(":")
                #strip leading comma if any and surrounding whitespace.
                if temp[0] =~ /,?\s*(\S+)\s*/
                    key_name = $1
                    key = -1
                    if key_name =~ /\D*(\d+)/
                        key = SafeParse.to_int("C-state name for component #{component_name}", $1)
                    end
                    if(temp[1] != nil)
                        temp[1] = temp[1].strip
                        value = SafeParse.to_float("C-state residency for component #{component_name}, state #{key}", temp[1])
                        powermetrics.component[component_name].cstates_map[key] = value
                    end
                end
            }
        end
    end
    
    def PowerUsage.print_package_residency(component)
        component.print_cstate_residency_header
        component.print_cstate_residency
    end
    
    def PowerUsage.print_backlight_info(powermetrics)
        puts "Backlight level".ljust(PowerUsage::LEFT_WIDTH) + HSEP + powermetrics.backlight_level.to_s.rjust(PowerUsage::RIGHT_WIDTH)
    end
    
    def PowerUsage.mini_backlight(powermetrics, output_dict)
        output_dict.add("backlight_level", powermetrics.backlight_level)
    end

    def PowerUsage.print_battery_info(powermetrics)
        puts "Plugged In?".ljust(PowerUsage::LEFT_WIDTH) + HSEP + powermetrics.plugged_in.rjust(PowerUsage::RIGHT_WIDTH)
        puts "Max capacity (%Design)".ljust(PowerUsage::LEFT_WIDTH) + HSEP +
            SafeParse.float_to_string(powermetrics.percent_charge_of_design).rjust(PowerUsage::RIGHT_WIDTH)
        puts "Charge remaining (%Max)".ljust(PowerUsage::LEFT_WIDTH) + HSEP +
            SafeParse.float_to_string(powermetrics.percent_charge_remaining).rjust(PowerUsage::RIGHT_WIDTH)
        puts "Cycle Count".ljust(PowerUsage::LEFT_WIDTH) + HSEP + powermetrics.cycle_count.to_s.rjust(PowerUsage::RIGHT_WIDTH)
    end
    
    def PowerUsage.mini_battery(powermetrics, output_dict)
        output_dict.add("power_plugged_in", powermetrics.plugged_in)
        output_dict.add("battery_fcc_percent_of_design", powermetrics.percent_charge_of_design)
        output_dict.add("battery_remaining_percent_of_fcc", powermetrics.percent_charge_remaining)
        output_dict.add("battery_cycle_count", powermetrics.cycle_count)
    end

    def PowerUsage.parse_frequency(powermetrics, line, component_name)
        if(powermetrics.component[component_name] == nil)
            powermetrics.component[component_name] = ComponentPowerStats.new(component_name)
        end
        fields = line.split(":")
        if (fields[1] != nil)
            powermetrics.component[component_name].frequency = SafeParse.to_string("PowerUsage/AvgFrequency", fields[1])
        end
        
    end
    
    def PowerUsage.print_package_frequency(component)
        info = "Average frequency as fraction of nominal: " + component.frequency + "\n"
        puts info
    end

    # Place-holder for analysis that highlights interrupt storms
    def PowerUsage.parse_interrupt_distribution(powermetrics, lines)
        powermetrics.interrupts = lines
    end

    def PowerUsage.print_interrupts(lines)
        lines.each { |line|
            puts line
        }
    end
        
    def PowerUsage.parse_package_info(powermetrics, lines, detailed)
        lines.each { |line|
            case line
                when /^(Package \d+) C-state residency/
                    parse_cstate_residency(powermetrics, line, $1)
                when /^(Core \d+) C-state residency/
                    if(detailed == true)
                        parse_cstate_residency(powermetrics, line, $1)
                    end
                when /^System Average frequency as fraction of nominal/
                    # Cheat for now and attribute to Package 0 since there is only one frequency plane.
                    parse_frequency(powermetrics, line, "Package 0")
            end
        }
    end

    def PowerUsage.parse_gpu_info(powermetrics, lines)
        lines.each { |line|
            case line
                when /^(GPU \d+) C-state residency/
                    parse_cstate_residency(powermetrics, line, $1)
                when /^(GPU \d+) average frequency as fraction of nominal/
                    parse_frequency(powermetrics, line, $1)
            end
        }
    end
    
    def PowerUsage.parse_all(path, detailed)
        powermetrics = PowerMetricsState.new
        begin
            content_map = Hash.new
            parse_file(powermetrics, path, detailed, content_map)
            content_map.keys.each { |subsection_name|
                case subsection_name
                    when PowerUsage::SUBSECTION_BATTERY_BACKLIGHT
                        parse_battery_info(powermetrics, content_map[subsection_name])
                    when PowerUsage::SUBSECTION_PROCESSOR_USAGE
                        powermetrics.supported_processor = true
                        parse_package_info(powermetrics, content_map[subsection_name], detailed)
                    when PowerUsage::SUBSECTION_GPU_USAGE
                        parse_gpu_info(powermetrics, content_map[subsection_name])
                    when PowerUsage::SUBSECTION_THERMAL_PRESSURE
                        parse_thermal_pressure(powermetrics, content_map[subsection_name])
                    when PowerUsage::SUBSECTION_INTERRUPT_DISTRIBUTION
                        if(detailed ==true)
                            parse_interrupt_distribution(powermetrics, content_map[subsection_name])
                        end
                end
            }
            return powermetrics
        rescue Exception => e
            $stderr.puts "ERROR: An unexpected error occured while parsing powermetrics."
            $stderr.puts "Please open a radar with this sysdiagnose"
            $stderr.puts e.message
            $stderr.puts e.backtrace.inspect
            return nil
        end
    end

    def PowerUsage.print_summary(powermetrics)
        begin
            print_battery_info(powermetrics)
            print_backlight_info(powermetrics)
            print_thermal_info(powermetrics)
            if (powermetrics.supported_processor == true)
                powermetrics.component.values.each { |component|
                    if(component.component_name.start_with?("Package") or component.component_name.start_with?("GPU"))
                        SysTriage.subsection_separator("#{component.component_name} Info")
                        print_package_residency(component)
                        print_package_frequency(component)
                    end
                }
            else
                $stderr.puts "System does not support publishing of C-states / P-states"
            end
        rescue Exception => e
            $stderr.puts "ERROR: Unexpected error while parsing powermetrics. "
            $stderr.puts "ERROR: Please open a radar with the sysdiagnose being analyzed. "
        end
    end
    
    def PowerUsage.mini(powermetrics, output_dict)
        begin
            mini_battery(powermetrics, output_dict)
            mini_backlight(powermetrics, output_dict)
            mini_thermal_info(powermetrics, output_dict)
            if (powermetrics.supported_processor == true)
                powermetrics.component.values.each { |component|
                    if(component.component_name.start_with?("Package") or component.component_name.start_with?("GPU"))
                        component.mini(output_dict)
                    end
                }
            else
                $stderr.puts "System does not support publishing of C-states / P-states"
            end
            rescue Exception => e
            $stderr.puts "ERROR: Unexpected error while parsing powermetrics. "
            $stderr.puts "ERROR: Please open a radar with the sysdiagnose being analyzed. "
        end
    end
    
    def PowerUsage.print_details(powermetrics)
        begin
            if (powermetrics.supported_processor == true)
                powermetrics.component.values.each { |component|
                    if(!component.component_name.start_with?("Package") and !component.component_name.start_with?("GPU"))
                        SysTriage.subsection_separator("#{component.component_name} Info")
                        print_package_residency(component)
                    end
                }
            else
                $stderr.puts "System does not support publishing of C-states / P-states"
            end
            SysTriage.subsection_separator("Interrupt Info")
            print_interrupts(powermetrics.interrupts)
        rescue Exception => e
            $stderr.puts "ERROR: Unexpected error while parsing powermetrics. "
            $stderr.puts "ERROR: Please open a radar with the sysdiagnose being analyzed. "
        end
    end
end


################################################################################
########## IO Tasks ############################################################
################################################################################

module FSUsage
    INDEX_EXECNAME = 0
    INDEX_PID      = 1
    
    class IOobj
        attr_accessor :disk_time, :num_disk_io, :disk_bytes, :num_io, :io_bytes,
            :rd_data, :wr_data, :rd_meta, :wr_meta, :iocsync,
            :pg_in_count, :pg_out_count, :pg_in_bytes, :pg_out_bytes,
            :pid, :execname, :issue_delay_sum_square, :disk_time_sum_square

        def initialize(init_pid, init_execname)
            @disk_time    = 0.0
            @num_disk_io  = 0
            @disk_bytes   = 0
            @num_io       = 0
            @io_bytes     = 0
            @rd_data      = 0
            @wr_data      = 0
            @rd_meta      = 0
            @wr_meta      = 0
            @pg_in_count  = 0
            @pg_out_count = 0
            @pg_in_bytes  = 0
            @pg_out_bytes = 0
            @iocsync      = 0
            @pid          = init_pid
            @execname     = init_execname
            @issue_delay_sum_square = 0
            @disk_time_sum_square   = 0
        end
    end

    class FSUsageParseResults
        attr_accessor :all_info, :disk_bytes_list, :io_bytes_list, :num_io_list

        def initialize(*args)
            @all_info        = args[0]
            @disk_bytes_list = args[1]
            @io_bytes_list   = args[2]
            @num_io_list     = args[3]
        end
    end

    TS_FORMAT = '%H:%M:%S.%N'

    # expects list of (start, end) timestamps pairs, sorted in decreasing order of end timestamp
    # returns root-mean-square of disk queue length
    # Currently unused for perf reasons (constructing the input array is expensive).
    # Likely to be permanently superseded by better metrics.
    def FSUsage.calc_queue_length(all_disk_ios)
        queue_length_total = 1
        queue_length_count = 1
        
        for i in 0...all_disk_ios.length
            queue_length = 1
            # iterate through all ios completed before me
            for j in (i + 1)...all_disk_ios.length
                # if I was started before the previous ios ended, increase queue length
                if all_disk_ios[i][0] < all_disk_ios[j][1]
                    queue_length += 1
                else
                    break
                end
            end

            queue_length_total += queue_length * queue_length
            queue_length_count += 1
        end

        return Math.sqrt(queue_length_total / queue_length_count)
    end

    # parse: string * (int, [string, int]) hash * bool * string list -> FSUsageParseResults
    # Perf note: I've squeezed this as much as possible. > 90% of cpu use is in the regex
    # which is unavoidable
    def FSUsage.parse(path, thread_to_process_map, detailed, io_blacklist, top_n)
        file = File.open(path, SYSDIAGNOSE_ENCODING)
        io_hash      = {}
        all_info     = IOobj.new(0, "SYSTRIAGE_TOTAL")
        all_disk_ios = [] # list of (start, end) timestamps pairs, sorted in increasing order of end timestamp

        r_disk_operations = /RdMeta|WrMeta|RdData|WrData|PgIn|PgOut|IOCTL/
        r_disk_options    = /\[.*\]/
        r_fs_op           = /\S+/
        r_op              = /#{r_disk_operations}#{r_disk_options}?/
        if detailed
            r_op = /#{r_disk_operations}#{r_disk_options}?|#{r_fs_op}/
        end

        r_hour = /[0-1]\d|2[0-3]/
        r_min  = /[0-5]\d/
        r_sec  = /[0-5]\d/
        r_usec = /\d{6}/

        r_args        = /.*/
        r_arg_size    = /B=(0x[0-9a-fA-F]+)/
        r_arg_iocsync = /<DKIOCSYNCHRONIZECACHE>/

        r_duration    = /\d+\.#{r_usec}/
        r_wait        = /W|\s/
        r_execname    = /\S.*/
        r_thread_id   = /\d+/

        r_whole_line = /^(#{r_hour}):(#{r_min}):(#{r_sec})\.(#{r_usec})\s+(#{r_op})\s+(#{r_args})\s+(#{r_duration})\s#{r_wait}\s(#{r_execname})\.(#{r_thread_id})$/

        year  = 1900
        month = 01
        day   = 01
        last_completion_time = Time.mktime(year, month, day, 0, 0, 0, 0)

        file.each{|line|
            line = SafeParse.encode_string("FSUsage/line", line)
            if line =~ r_whole_line
                hour_s      = $1
                min_s       = $2
                sec_s       = $3
                usec_s      = $4
                operation   = $5
                args        = $6
                duration_s  = $7
                execname    = $8
                thread_id   = $9.to_i()

                if io_blacklist.include?(execname)
                    next
                end

                process    = thread_to_process_map[thread_id]

                # There are instances where processes cannot be found from their
                # thread id.  This is just a race condition between spindump
                # and fs_usage
                if process == nil
                    process = Array.new
                    process[FSUsage::INDEX_PID] = 0
                    process[FSUsage::INDEX_EXECNAME] = execname
                end

                proc_info = io_hash[process]
                if proc_info == nil
                    proc_info        = IOobj.new(process[FSUsage::INDEX_PID], process[FSUsage::INDEX_EXECNAME])
                    io_hash[process] = proc_info
                end

                size = 0
                if (args =~ r_arg_size)
                    size = $1.to_i(16)
                end

                case operation
                    when /(#{r_disk_operations})/
                        disk_operation = $1
                        if disk_operation == "IOCTL" and not args =~ r_arg_iocsync
                            next
                        end

                        hour     = hour_s.to_i
                        min      = min_s.to_i
                        sec      = sec_s.to_i
                        usec     = usec_s.to_i
                        duration = duration_s.to_f
                        completion_time = Time.mktime(year, month, day, hour, min, sec, usec)
                        # Moved across a date boundary. Need to add a day.
                        if completion_time < last_completion_time
                            comletion_time += SECONDS_IN_DAY
                        end

                        start_time = completion_time - duration
                        issue_delay = last_completion_time - start_time

                        if issue_delay <= 0
                            issue_delay = 0
                        else
                            start_time = last_completion_time
                            issue_delay_square = issue_delay * issue_delay
                            proc_info.issue_delay_sum_square += issue_delay_square
                            all_info.issue_delay_sum_square += issue_delay_square
                        end

                        io_duration = (completion_time - start_time)
                        io_duration_square = io_duration * io_duration
                        last_completion_time = completion_time

                        proc_info.disk_time   += io_duration
                        proc_info.num_disk_io += 1
                        proc_info.disk_bytes  += size
                        proc_info.disk_time_sum_square += io_duration_square

                        all_info.disk_time    += io_duration
                        all_info.num_disk_io  += 1
                        all_info.disk_bytes   += size
                        all_info.disk_time_sum_square += io_duration_square

                        case disk_operation
                            when "WrData"
                                proc_info.wr_data      += size
                            when "RdData"
                                proc_info.rd_data      += size
                            when "WrMeta"
                                proc_info.wr_meta      += size
                            when "RdMeta"
                                proc_info.rd_meta      += size
                            when "PgIn"
                                proc_info.pg_in_count  += 1
                                proc_info.pg_in_bytes  += size
                            when "PgOut"
                                proc_info.pg_out_count += 1
                                proc_info.pg_out_bytes += size
                            when "IOCTL"
                                # we already checked for DKIOCSYNCHRONIZE in args
                                proc_info.iocsync += 1
                        end

                    when /^(PAGE_IN_FILE|PAGE_OUT_FILE)/
                        proc_info.io_bytes += KILOBYTE * 4
                        proc_info.num_io   += 1
                        all_info.io_bytes  += KILOBYTE * 4
                        all_info.num_io    += 1

                    when /^(mmap|msync)/
                        next

                    else
                        proc_info.io_bytes += size
                        proc_info.num_io   += 1
                        all_info.io_bytes  += size
                        all_info.num_io    += 1
                end
            end
        }
        
        file.close()

        sums            = io_hash.values
        if top_n <= 0
            top_n = sums.length
        end
        disk_bytes_list = sums.sort{|a, b| b.disk_bytes <=> a.disk_bytes}[0, top_n]
        io_bytes_list   = sums.sort{|a, b| b.io_bytes <=> a.io_bytes}[0, top_n]
        num_io_list    = sums.sort{|a, b| b.num_io <=> a.num_io}[0, top_n]

        return FSUsageParseResults.new(all_info, disk_bytes_list, io_bytes_list, num_io_list)
    end

    PID_WIDTH        = 8
    COMMAND_WIDTH    = 16
    FIELD_WIDTH      = 8
    DESC_LENGTH      = 24

    # fields is an array of (string, IOObj -> string) tuples, where the string is the title
    # of a value to be displayed, and the second argument is a lambda that projects this value
    # out as a string for printing. print_fields will justify the string as required
    def FSUsage.print_fields(list, fields)
        header1 = ["PID".rjust(FSUsage::PID_WIDTH), "COMMAND".ljust(FSUsage::COMMAND_WIDTH)].join(" ")
        header2 = fields.map{|field| field[0].rjust(FSUsage::FIELD_WIDTH)}.join(" ")
        headers = [header1, header2]
        separators = headers.map{|h| VSEP * h.length}
        
        header    = headers.join(HSEP)
        separator = separators.join(HSEP)
        
        puts("")
        puts(header)
        puts(separator)
        
        list.each{|proc_info|
            execname  = proc_info.execname.ljust(FSUsage::COMMAND_WIDTH)
            if execname.length > FSUsage::COMMAND_WIDTH
                execname = execname[0...FSUsage::COMMAND_WIDTH]
            end

            left  = [proc_info.pid.to_s.rjust(FSUsage::PID_WIDTH), execname].join(" ")
            right = fields.map{|field| field[1].call(proc_info).rjust(FSUsage::FIELD_WIDTH)}.join(" ")
            puts [left, right].join(HSEP)
        }
    end

    # columns is an array of triples of the following type:
    # (string, ((process, FSUsage.IOObj) Array), (FSUsage.IOObj -> string))
    # The first is a string which is the title of the metric being printed
    # The second is the input array which is sorted by the required metric
    # and clipped to the desired threshold.
    # Third is a lambda that projects the metric to be printed out of a IOObj
    # and formats it as a string. print_columns will justify the string as required.
    def FSUsage.print_columns(columns)
        headers = columns.map{|f|
            title = f[0]
            [title.rjust(FSUsage::FIELD_WIDTH), "PID".rjust(FSUsage::PID_WIDTH), "COMMAND".ljust(FSUsage::COMMAND_WIDTH)].join(" ")
        }
        separators = headers.map{|h| VSEP * h.length}

        header    = headers.join(HSEP)
        separator = separators.join(HSEP)
        puts("")
        puts(header)
        puts(separator)
        
        top_n = 0
        columns.each { |c|
            if c[1].length > top_n
                top_n = c[1].length
            end
        }

        for i in 0...top_n
            ents = []
            have_something = false
            columns.each_index{|j|
                c    = columns[j]
                list = c[1]
                proj = c[2]
                if i < list.length
                    proc_info = list[i]
                    ent       = [proj.call(proc_info).rjust(FSUsage::FIELD_WIDTH), proc_info.pid.to_s.rjust(FSUsage::PID_WIDTH)]
                    execname  = proc_info.execname.ljust(FSUsage::COMMAND_WIDTH)

                    if execname.length > FSUsage::COMMAND_WIDTH
                        execname = execname[0...FSUsage::COMMAND_WIDTH]
                    end

                    ent  << execname
                    ents << ent.join(" ")
                    have_something = true
                else
                    ents << " " * headers[j].length
                end
            }

            if have_something
                puts ents.join(HSEP)
                else
                puts ""
                return
            end
        end
        
        puts ""
        return
    end

    def FSUsage.print_summary(results)
        all_info = results.all_info

        puts "Disk Active Time : ".rjust(FSUsage::DESC_LENGTH) + SafeParse.float_to_string(all_info.disk_time) + "s"
        disk_time_rms = 0
        queue_time_rms = 0
        if all_info.num_disk_io > 0
            disk_time_rms = Math.sqrt(all_info.disk_time_sum_square / all_info.num_disk_io)
            queue_time_rms = Math.sqrt(all_info.issue_delay_sum_square / all_info.num_disk_io)
        end
        puts "Op Disk Duration RMS : ".rjust(FSUsage::DESC_LENGTH) + SafeParse.float_to_string_with_precision(disk_time_rms, 6) + "s"
        puts "Op Queue Duration RMS : ".rjust(FSUsage::DESC_LENGTH) + SafeParse.float_to_string_with_precision(queue_time_rms, 6) + "s"
        puts "Number of Disk Ops : ".rjust(FSUsage::DESC_LENGTH) + all_info.num_disk_io.to_s
        puts "Total Disk Bytes : ".rjust(FSUsage::DESC_LENGTH) + SafeParse.byte_to_string(all_info.disk_bytes)

        column_disk_bytes = ["DiskByte", results.disk_bytes_list, lambda {|x| SafeParse.byte_to_string(x.disk_bytes)}]

        if column_disk_bytes[1].length > 0
            FSUsage.print_columns([column_disk_bytes])
        end
    end
    
    def FSUsage.mini(results, output_dict)
        if results.disk_bytes_list.length > 0
            output_dict.add("top_disk_proc", results.disk_bytes_list[0].execname)
            output_dict.add("top_disk_bytes", results.disk_bytes_list[0].disk_bytes)
            output_dict.add("top_disk_ops", results.disk_bytes_list[0].num_disk_io)
        end
    end
    
    def FSUsage.print_verbose(results)
        print_fields(results.disk_bytes_list,
                     [["DiskTime", lambda {|x| (SafeParse.float_to_string(x.disk_time) + "s")}],
                     ["DiskIOs" , lambda {|x| x.num_disk_io.to_s}],
                     ["DiskByte", lambda {|x| SafeParse.byte_to_string(x.disk_bytes)}],
                     ["IOCSYNC" , lambda {|x| x.iocsync.to_s}]])
        print_fields(results.disk_bytes_list,
                     [["RdData"  , lambda {|x| SafeParse.byte_to_string(x.rd_data)}],
                     ["WrData"  , lambda {|x| SafeParse.byte_to_string(x.wr_data)}],
                     ["RdMeta"  , lambda {|x| SafeParse.byte_to_string(x.rd_meta)}],
                     ["WrMeta"  , lambda {|x| SafeParse.byte_to_string(x.wr_meta)}]])
        print_fields(results.disk_bytes_list,
                     [["PgIns"   , lambda {|x| x.pg_in_count.to_s}],
                     ["PgInByte", lambda {|x| SafeParse.byte_to_string(x.pg_in_bytes)}],
                     ["PgOuts"  , lambda {|x| x.pg_out_count.to_s}],
                     ["PgOutByt", lambda {|x| SafeParse.byte_to_string(x.pg_out_bytes)}]])
        
        all_info = results.all_info

        puts "\n\n"
        puts "Number of IO Ops : ".rjust(FSUsage::DESC_LENGTH) + all_info.num_io.to_s
        puts "Total IO Bytes : ".rjust(FSUsage::DESC_LENGTH) + SafeParse.byte_to_string(all_info.io_bytes)
        
        column_io_bytes = ["IO Bytes", results.io_bytes_list, lambda {|x| SafeParse.byte_to_string(x.io_bytes)}]
        column_num_io   = ["IO Count", results.num_io_list  , lambda {|x| x.num_io.to_s}]
        
        columns = [column_io_bytes, column_num_io].reject{|c| c[1].length == 0}
        FSUsage.print_columns(columns)
    end
end


################################################################################
########## Stack stuff #########################################################
################################################################################

SPINDUMP_MINIMUM_SAMPLE_MS = 100

module Spindump
    PROCESS_LINE_REGEX = /^Process:\s+(\S.*)\s\[(\d+)\](\s\(zombie\))?$/

    def Spindump.make_thread_to_process_map(path)
        process = []
        proc_hash = {}
        file = File.open(path, SYSDIAGNOSE_ENCODING)

        file.each{|line|
            line = SafeParse.encode_string("Spindump/line", line)
            case line
                when PROCESS_LINE_REGEX
                    process = Array.new
                    process[FSUsage::INDEX_EXECNAME] = $1
                    process[FSUsage::INDEX_PID]      = $2.to_i()
                    proc_hash[process] = []
                when /^\s*Thread\s0x([0-9a-fA-F]+)/
                    proc_hash[process] << $1.to_i(16)
            end
        }

        file.close()

        thread_to_process_map = {}
        # This is a crucial part of the code where the hash is converted from a process -> threads hash
        # and into a threads -> process hash
        proc_hash.map{|k, v| v.map{|f| {f => k}}}.flatten.each{|x| thread_to_process_map.merge!(x)}
        return thread_to_process_map
    end

    module PrinterState
        PROC_INACTIVE   = 0
        PROC_HEADER     = 1
        THREAD_BODY     = 2
        THREAD_INACTIVE = 3
    end

    class SpindumpProc
        attr_accessor :pid, :cpu, :header, :thread_list
        
        def initialize
            @pid         = 0
            @cpu         = 0.0
            @header      = []
            @thread_list = []
        end
    end

    class SpindumpThread
        attr_accessor :cpu, :body
        
        def initialize
            @cpu  = 0.0
            @body = []
        end
    end

    def Spindump.parse_threads(path, top_cpu_pid_list)
        file          = File.open(path, SYSDIAGNOSE_ENCODING)
        duration      = ""
        steps         = ""
        sampling_rate = 10 #Assume it is 10 ms. Fix it if the file says otherwise

        time_threshold   = 0.1 #seconds
        sample_threshold = SPINDUMP_MINIMUM_SAMPLE_MS / sampling_rate
        pid              = 0
        thread_info      = ""

        state = PrinterState::PROC_INACTIVE
        proc_list = []
        proc      = nil
        thread    = nil

        file.each{|line|
            line = SafeParse.encode_string("Spindump/line", line)
            #state changes and things that need to happen when the state changes
            case line
                when PROCESS_LINE_REGEX
                    pid = $2.to_i()
                    case state
                        when PrinterState::PROC_INACTIVE
                            # nothing to be done
                        when PrinterState::PROC_HEADER
                            ErrorLog.report("Spindump Printer: Previous process header was not followed by threads")
                            return ["", "", []]
                        when PrinterState::THREAD_BODY
                            proc.thread_list << thread
                            proc_list << proc
                        when PrinterState::THREAD_INACTIVE
                            proc_list << proc
                    end

                    state    = PrinterState::PROC_HEADER
                    proc     = SpindumpProc.new()
                    proc.pid = pid

                when /^CPU Time:\s+(\d+\.\d+)s/
                    cpu = $1.to_f()
                    if state != PrinterState::PROC_HEADER
                        ErrorLog.report("Spindump Printer: CPU Time reported, but we've not seen a proc header")
                        return ["", "", []]
                    end

                    proc.cpu = cpu
                    # Simplify code -- check both pid and cpu threshold in one place
                    if proc.cpu <= time_threshold or not top_cpu_pid_list.include?(proc.pid)
                        state = PrinterState::PROC_INACTIVE
                        proc  = nil
                        next
                    end

                when /^\s*Thread\s(0x[0-9a-fA-F]|<multiple>)+/
                    case state
                        when PrinterState::THREAD_BODY
                            proc.thread_list << thread
                        when PrinterState::PROC_INACTIVE
                            next
                        when PrinterState::PROC_HEADER
                            if not proc.cpu > time_threshold or not top_cpu_pid_list.include?(proc.pid)
                                state = PrinterState::PROC_INACTIVE
                                proc  = nil
                                next
                            end
                        else # THREAD_INACTIVE OR PROC_HEADER -- nothing to save or skip
                    end

                    state = PrinterState::THREAD_BODY
                    thread = SpindumpThread.new()
                    if line =~ /cpu time\s+(\d+\.\d+)s/
                        thread.cpu = $1.to_f()
                    end

                    if thread.cpu < time_threshold
                        state  = PrinterState::THREAD_INACTIVE
                        thread = nil
                        next
                    end

                # Following two cases eat up lines pertaining to binary images.
                when /Binary Images:$/
                    case state
                        when PrinterState::PROC_INACTIVE #nothing to do
                        when PrinterState::PROC_HEADER
                            ErrorLog.report("Spindump Printer: Binary Image info before any threads have been seen")
                            return ["", "", []]
                        when PrinterState::THREAD_BODY
                            proc.thread_list << thread
                            state = PrinterState::THREAD_INACTIVE
                        when PrinterState::THREAD_INACTIVE #nothing to do
                    end

                when /^Duration:/
                    duration = line

                when /^Steps:\s+\d+\s\((\d+)ms\ssampling\sinterval\)$/
                    steps = line
                    sampling_rate = $1.to_i()
                    sample_threshold = SPINDUMP_MINIMUM_SAMPLE_MS / sampling_rate
            end

            # Factor out this code, because every line gets stashed away in one of two places
            case state
                when PrinterState::PROC_HEADER
                    proc.header << line
                when PrinterState::THREAD_BODY
                    if line =~ /^\s*\*?(\d+)\s+\S+/
                        num_samples = $1.to_i
                        if num_samples <= sample_threshold
                            next
                        end
                    end
                    thread.body << line
                else #PROC_INACTIVE OR THREAD_INACTIVE -- skip current line
                    next
            end
        }

        if thread != nil and proc != nil
            proc.thread_list << thread
        end

        if proc != nil
            proc_list << proc
        end

        proc_list.sort!{|x, y| y.cpu <=> x.cpu}

        proc_list.each{|p|
            p.thread_list.sort!{|x, y| y.cpu <=> x.cpu}
        }

        file.close()
        return [duration, steps, proc_list]
    end

    def Spindump.print_summary(path, top_cpu_list)
        top_cpu_pid_list = top_cpu_list.map{|x| x.pid}
        (duration, steps, proc_list) = parse_threads(path, top_cpu_pid_list)

        puts ""
        puts "Filtered Spindump output: (Minimum stack sample times: #{SPINDUMP_MINIMUM_SAMPLE_MS}ms)"
        puts "#{duration}"
        puts "#{steps}".chomp
        puts ""
        
        proc_list.each{|p|
            p.header.each{|h| puts h}
            p.thread_list.each{|t|
                t.body.each{|line| puts line}
            }
        }
    end
end

################################################################################
########## Top #################################################################
################################################################################

module Top
    class TopParseResults
        attr_accessor :cpu_list, :idlew_list, :power_list,
            :rprvt_list, :rshrd_list, :rsize_list,
            :vprvt_list, :vsize_list, :mregs_list,
            :mem_list, :purg_list, :kprvt_list,
            :ports_list, :cmprs_list, :total_footprint_list

        def initialize(*args)
            @cpu_list   = args[0]
            @idlew_list = args[1]
            @power_list = args[2]
            @rprvt_list = args[3]
            @rshrd_list = args[4]
            @rsize_list = args[5]
            @vprvt_list = args[6]
            @vsize_list = args[7]
            @mregs_list = args[8]
            @mem_list   = args[9]
            @purg_list  = args[10]
            @kprvt_list = args[11]
            @ports_list = args[12]
            @cmprs_list = args[13]
            @total_footprint_list = args[14]
        end
    end

    class ReportingThreshold
        attr_accessor :cpu, :idlew, :power,
        :rprvt, :rshrd, :rsize,
        :vprvt, :vsize, :mregs,
        :mem, :purg, :kprvt, :ports, :cmprs,
        :cpu_blacklist, :mem_blacklist, :top_n
        
        def initialize(*args)
            @cpu   = args[0]
            @idlew = args[1]
            @power = args[2]
            @rprvt = args[3]
            @rshrd = args[4]
            @rsize = args[5]
            @vprvt = args[6]
            @vsize = args[7]
            @mregs = args[8]
            @mem   = args[9]
            @purg  = args[10]
            @kprvt = args[11]
            @ports = args[12]
            @cmprs = args[13]
            @cpu_blacklist = args[14]
            @mem_blacklist = args[15]
            @top_n = args[16]
        end
    end

    class App
        attr_accessor :pid, :command, :cpu, :time, :th, :wq, :ports,
            :mregs, :rprvt, :rshrd, :rsize, :vprvt, :vsize,
            :pgrp, :ppid, :state, :uid, :faults, :cow, :msgsent, :msgrecv,
            :sysbsd, :sysmach, :csw, :pageins, :kprvt, :kshrd, :idlew, :power, :user,
            :mem, :purg, :cmprs, :total_footprint
        
        def initialize(*args)
            @pid      = args[0]
            @command  = args[1]
            @cpu      = args[2]
            @time     = args[3]
            @th       = args[4]
            @wq       = args[5]
            @ports    = args[6]
            @mregs    = args[7]
            @rprvt    = args[8]
            @rshrd    = args[9]
            @rsize    = args[10]
            @vprvt    = args[11]
            @vsize    = args[12]
            @pgrp     = args[13]
            @ppid     = args[14]
            @state    = args[15]
            @uid      = args[16]
            @faults   = args[17]
            @cow      = args[18]
            @msgsent  = args[19]
            @msgrecv  = args[20]
            @sysbsd   = args[21]
            @sysmach  = args[22]
            @csw      = args[23]
            @pageins  = args[24]
            @kprvt    = args[25]
            @kshrd    = args[26]
            @idlew    = args[27]
            @power    = args[28]
            @user     = args[29]
            @mem      = args[30]
            @purg     = args[31]
            @cmprs    = args[32]
            @total_footprint = args[33]
        end
    end

    # The object storing the current machine's configuration
    class Machine
        attr_accessor :used_mem, :free_mem,
            :network_in, :network_bytes_in, :network_out, :network_bytes_out,
            :disk_read, :disk_bytes_read, :disk_written, :disk_bytes_written,
            :swapins, :swapouts, :cpu_user, :cpu_system, :cpu_idle

        def initialize(*args)
            @used_mem           = args[0]
            @free_mem           = args[1]
            @network_in         = args[2]
            @network_bytes_in   = args[3]
            @network_out        = args[4]
            @network_bytes_out  = args[5]
            @disk_read          = args[6]
            @disk_bytes_read    = args[7]
            @disk_written       = args[8]
            @disk_bytes_written = args[9]
            @swapins            = args[10]
            @swapouts           = args[11]
            @cpu_user           = args[12]
            @cpu_system         = args[13]
            @cpu_idle           = args[14]
        end
    end

    def Top.parse_machine_state(machine_text)
        used_mem           = 0
        free_mem           = 0
        network_in         = 0
        network_bytes_in   = 0
        network_out        = 0
        network_bytes_out  = 0
        disk_read          = 0
        disk_bytes_read    = 0
        disk_written       = 0
        disk_bytes_written = 0
        swapins            = 0
        swapouts           = 0
        cpu_user           = 0.0
        cpu_system         = 0.0
        cpu_idle           = 0.0

        machine_text.each{|line|
            case line
                when /^PhysMem:/
                    if line =~ /\s(\d+(B|K|M|G|T))\sused/
                        used_mem = SafeParse.to_byte("top/used_mem", $1)
                    else
                        ErrorLog.report("No match for top/used_mem")
                    end
                
                    if line =~ /\s(\d+(B|K|M|G|T))\s(unused|free)/
                        free_mem = SafeParse.to_byte("top/free_mem", $1)
                    else
                        ErrorLog.report("No match for top/free_mem")
                    end
                when /^Networks:/
                    if line =~ /\s(\d+)\/(\d+(B|K|M|G|T))\sin/
                        network_in       = $1.to_i
                        network_bytes_in = SafeParse.to_byte("top/net_in", $2)
                    else
                        ErrorLog.report("No match for top/net_in")
                    end

                    if line =~ /\s(\d+)\/(\d+(B|K|M|G|T))\sout/
                        network_out       = $1.to_i
                        network_bytes_out = SafeParse.to_byte("top/net_out", $2)
                    else
                        ErrorLog.report("No match for top/net_out")
                    end
                when /^Disks:/
                    if line =~ /\s(\d+)\/(\d+(B|K|M|G|T))\sread/
                        disk_read       = $1.to_i
                        disk_bytes_read = SafeParse.to_byte("top/disk_read", $2)
                    else
                        ErrorLog.report("No match for top/disk_read")
                    end
                
                    if line =~ /\s(\d+)\/(\d+(B|K|M|G|T))\swritten/
                        disk_written       = $1.to_i
                        disk_bytes_written = SafeParse.to_byte("top/disk_written", $2)
                    else
                        ErrorLog.report("No match for top/disk_written")
                    end
                when /^VM:/
                    if line =~ /\s\d+\((\d+)\)\s(pageins|swapins)/
                        swapins = $1.to_i
                    else
                        ErrorLog.report("No match for top/swapins")
                    end

                    if line =~ /\s\d+\((\d+)\)\s(pageouts|swapouts)/
                        swapouts = $1.to_i
                    else
                        ErrorLog.report("No match for top/swapouts")
                    end
                when /^CPU usage:\s+(\d+\.\d+)%\s+user,\s+(\d+\.\d+)%\s+sys,\s+(\d+\.\d+)%\s+idle/
                    cpu_user   = SafeParse.to_float("top/cpu_user", $1)
                    cpu_system = SafeParse.to_float("top/cpu_system", $2)
                    cpu_idle   = SafeParse.to_float("top/cpu_idle", $3)
            end
        }
        
        return Machine.new(used_mem, free_mem, network_in, network_bytes_in,
                           network_out, network_bytes_out, disk_read, disk_bytes_read,
                           disk_written, disk_bytes_written, swapins, swapouts,
                           cpu_user, cpu_system, cpu_idle)
    end

    def Top.parse_machine_sum(machine_states)
        machine_sum = Machine.new(machine_states[0].used_mem, machine_states[0].free_mem,
                                  0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                  machine_states[0].cpu_user, machine_states[0].cpu_system, machine_states[0].cpu_idle)

        for i in 1...(machine_states.length)
            machine_sum.network_in         += machine_states[i].network_in
            machine_sum.network_bytes_in   += machine_states[i].network_bytes_in
            machine_sum.network_out        += machine_states[i].network_out
            machine_sum.network_bytes_out  += machine_states[i].network_bytes_out
            machine_sum.disk_read          += machine_states[i].disk_read
            machine_sum.disk_bytes_read    += machine_states[i].disk_bytes_read
            machine_sum.disk_written       += machine_states[i].disk_written
            machine_sum.disk_bytes_written += machine_states[i].disk_bytes_written
            machine_sum.swapins            += machine_states[i].swapins
            machine_sum.swapouts           += machine_states[i].swapouts
            machine_sum.cpu_user           += machine_states[i].cpu_user
            machine_sum.cpu_system         += machine_states[i].cpu_system
            machine_sum.cpu_idle           += machine_states[i].cpu_idle
        end
        
        machine_sum.cpu_user   /= machine_states.length
        machine_sum.cpu_system /= machine_states.length
        machine_sum.cpu_idle   /= machine_states.length
        return machine_sum
    end

    def Top.parse_procs(procs)
        #remove the header information from top
        header = procs.shift
    
        pid_l       = 0...0
        command_l   = 0...0
        cpu_l       = 0...0
        time_l      = 0...0
        th_l        = 0...0
        wq_l        = 0...0
        ports_l     = 0...0
        mregs_l     = 0...0
        rprvt_l     = 0...0
        rshrd_l     = 0...0
        rsize_l     = 0...0
        vprvt_l     = 0...0
        vsize_l     = 0...0
        pgrp_l      = 0...0
        ppid_l      = 0...0
        state_l     = 0...0
        uid_l       = 0...0
        faults_l    = 0...0
        cow_l       = 0...0
        msgsent_l   = 0...0
        msgrecv_l   = 0...0
        sysbsd_l    = 0...0
        sysmach_l   = 0...0
        csw_l       = 0...0
        pageins_l   = 0...0
        kprvt_l     = 0...0
        kshrd_l     = 0...0
        idlew_l     = 0...0
        power_l     = 0...0
        user_l      = 0...0
        mem_l       = 0...0
        purg_l      = 0...0
        cmprs_l     = 0...0

        top_header = header.scan(/\S+\s+/){|c|
            range = ($~.offset(0)[0]...$~.offset(0)[1])
            case c
                when /^PID\s*/
                    pid_l = range
                when /^COMMAND\s*/
                    command_l = range
                when /^%CPU\s*/
                    cpu_l = range
                when /^TIME\s*/
                    time_l = range
                when /^#TH\s*/
                    th_l = range
                when /^#WQ\s*/
                    wq_l = range
                when /^#PORTS\s*/
                    ports_l = range
                when /^#MREGS\s*/
                    mregs_l = range
                when /^RPRVT\s*/
                    rprvt_l = range
                when /^RSHRD\s*/
                    rshrd_l = range
                when /^RSIZE\s*/
                    rsize_l = range
                when /^VPRVT\s*/
                    vprvt_l = range
                when /^VSIZE\s*/
                    vsize_l = range
                when /^PGRP\s*/
                    pgrp_l = range
                when /^PPID\s*/
                    ppid_l = range
                when /^STATE\s*/
                    state_l = range
                when /^UID\s*/
                    uid_l = range
                when /^FAULTS\s*/
                    faults_l = range
                when /^COW\s*/
                    cow_l = range
                when /^MSGSENT\s*/
                    msgsent_l = range
                when /^MSGRECV\s*/
                    msgrecv_l = range
                when /^SYSBSD\s*/
                    sysbsd_l = range
                when /^SYSMACH\s*/
                    sysmach_l = range
                when /^CSW\s*/
                    csw_l = range
                when /^PAGEINS\s*/
                    pageins_l = range
                when /^KPRVT\s*/
                    kprvt_l = range
                when /^KSHRD\s*/
                    kshrd_l = range
                when /^IDLEW\s*/
                    idlew_l = range
                when /^POWER\s*/
                    power_l = range
                when /^USER\s*/
                    user_l = range
                when /^MEM\s*/
                    mem_l = range
                when /^PURG\s*/
                    purg_l = range
                when /^CMPRS\s*/
                    cmprs_l = range
                end
        }

        # accumulator for process objects
        parsed_procs = []

        procs.each { |top_line|
            pid       = SafeParse.to_pid("top/pid", top_line[pid_l])
            command   = SafeParse.to_string("top/command", top_line[command_l])
            cpu       = SafeParse.to_float("top/%cpu", top_line[cpu_l])
            time      = SafeParse.to_string("top/time", top_line[time_l])
            th        = SafeParse.to_string("top/th", top_line[th_l]) # may have format int/int
            wq        = SafeParse.to_int("top/#wq", top_line[wq_l]) # may have format int/int
            ports     = SafeParse.to_int("top/#ports", top_line[ports_l])
            mregs     = SafeParse.to_int("top/#mregs", top_line[mregs_l])
            rprvt     = SafeParse.to_byte("top/rprvt", top_line[rprvt_l])
            rshrd     = SafeParse.to_byte("top/rshrd", top_line[rshrd_l])
            rsize     = SafeParse.to_byte("top/rsize", top_line[rsize_l])
            vprvt     = SafeParse.to_byte("top/vprvt", top_line[vprvt_l])
            vsize     = SafeParse.to_byte("top/vsize", top_line[vsize_l])
            pgrp      = SafeParse.to_int("top/pgrp", top_line[pgrp_l])
            ppid      = SafeParse.to_int("top/ppid", top_line[ppid_l])
            state     = SafeParse.to_string("top/state", top_line[state_l])
            uid       = SafeParse.to_int("top/UID", top_line[uid_l])
            faults    = SafeParse.to_int("top/faults", top_line[faults_l])
            cow       = SafeParse.to_int("top/cow", top_line[cow_l])
            msgsent   = SafeParse.to_int("top/msgsent", top_line[msgsent_l])
            msgrecv   = SafeParse.to_int("top/msgrecv", top_line[msgrecv_l])
            sysbsd    = SafeParse.to_int("top/sysbsd", top_line[sysbsd_l])
            sysmach   = SafeParse.to_int("top/sysmach", top_line[sysmach_l])
            csw       = SafeParse.to_int("top/csw", top_line[csw_l])
            pageins   = SafeParse.to_int("top/pageins", top_line[pageins_l])
            kprvt     = SafeParse.to_byte("top/kprvt", top_line[kprvt_l])
            kshrd     = SafeParse.to_byte("top/shrd", top_line[kshrd_l])
            idlew     = SafeParse.to_int("top/idlew", top_line[idlew_l])
            power     = SafeParse.to_float("top/power", top_line[power_l])
            user      = SafeParse.to_string("top/user", top_line[user_l])
            mem       = SafeParse.to_byte("top/mem", top_line[mem_l])
            purg      = SafeParse.to_byte("top/purg", top_line[purg_l])
            cmprs     = SafeParse.to_byte("top/cmprs", top_line[cmprs_l])
            total_footprint = mem + cmprs

            parsed_procs << App.new(pid, command, cpu, time, th, wq, ports, mregs,
                                    rprvt, rshrd, rsize, vprvt, vsize, pgrp, ppid,
                                    state, uid, faults, cow, msgsent, msgrecv, sysbsd,
                                    sysmach, csw, pageins, kprvt, kshrd, idlew, power, user,
                                    mem, purg, cmprs, total_footprint)
        }
        return parsed_procs
    end

    def Top.parse_proc_sum(proc_lists, top_thresholds)
        n_samples = proc_lists.length()
        if (n_samples < 1)
            ErrorLog.report("Top has no samples")
        else
            n_samples -= 1
        end
        
        sums_hash = {}
            
        # First sample for CPU, power, etc which depend on the
        # interval cannot be relied on. First sample for memory
        # which gives an absolute value can be used.
        #
        # If the system is really under memory pressure
        # adding up values from multiple samples is going to be
        # useless because of memory pressure/swapping. Just ignore those.
        proc_lists.each{|proc_list|
            proc_list.each{|app|
                if sums_hash[app.pid] == nil
                    sums_hash[app.pid]        = app.clone()
                    sums_hash[app.pid].cpu    = 0.0
                    sums_hash[app.pid].power  = 0.0
                    sums_hash[app.pid].idlew  = 0
                else
                    sums_hash[app.pid].cpu   += app.cpu
                    sums_hash[app.pid].power += app.power
                    sums_hash[app.pid].idlew += app.idlew
                end
            }
        }

        proc_sums = nil
        if (n_samples == 0)
            # All the cpu and power values are guaranteed to be 0 anyway.
            proc_sums = sums_hash.values()
        else
            proc_sums = sums_hash.values.map{|app|
                averaged        = app.clone()
                averaged.cpu   /= n_samples
                averaged.power /= n_samples
                averaged.idlew /= n_samples
                averaged
            }
        end

        top_n = top_thresholds.top_n
        if top_n <= 0
            top_n = proc_sums.length
        end

        cpu_list   = proc_sums.sort{|a, b| b.cpu   <=> a.cpu}
        cpu_list   = cpu_list.reject{|a| a.cpu <= top_thresholds.cpu or top_thresholds.cpu_blacklist.include?(a.command)}
        cpu_list   = cpu_list[0, top_n]

        idlew_list = proc_sums.sort{|a, b| b.idlew <=> a.idlew}
        idlew_list = idlew_list.reject{|a| a.idlew <= top_thresholds.idlew or top_thresholds.cpu_blacklist.include?(a.command)}
        idlew_list = idlew_list[0, top_n]

        power_list = proc_sums.sort{|a, b| b.power <=> a.power}
        power_list = power_list.reject{|a| a.power <= top_thresholds.power or top_thresholds.cpu_blacklist.include?(a.command)}
        power_list = power_list[0, top_n]

        rprvt_list = proc_sums.sort{|a, b| b.rprvt <=> a.rprvt}
        rprvt_list = rprvt_list.reject{|a| a.rprvt <= top_thresholds.rprvt or top_thresholds.mem_blacklist.include?(a.command)}
        rprvt_list = rprvt_list[0, top_n]

        rshrd_list = proc_sums.sort{|a, b| b.rshrd <=> a.rshrd}
        rshrd_list = rshrd_list.reject{|a| a.rshrd <= top_thresholds.rshrd or top_thresholds.mem_blacklist.include?(a.command)}
        rshrd_list = rshrd_list[0, top_n]

        rsize_list = proc_sums.sort{|a, b| b.rsize <=> a.rsize}
        rsize_list = rsize_list.reject{|a| a.rsize <= top_thresholds.rsize or top_thresholds.mem_blacklist.include?(a.command)}
        rsize_list = rsize_list[0, top_n]

        vprvt_list = proc_sums.sort{|a, b| b.vprvt <=> a.vprvt}
        vprvt_list = vprvt_list.reject{|a| a.vprvt <= top_thresholds.vprvt or top_thresholds.mem_blacklist.include?(a.command)}
        vprvt_list = vprvt_list[0, top_n]

        vsize_list = proc_sums.sort{|a, b| b.vsize <=> a.vsize}
        vsize_list = vsize_list.reject{|a| a.vsize <= top_thresholds.vsize or top_thresholds.mem_blacklist.include?(a.command)}
        vsize_list = vsize_list[0, top_n]

        mregs_list = proc_sums.sort{|a, b| b.mregs <=> a.mregs}
        mregs_list = mregs_list.reject{|a| a.mregs <= top_thresholds.mregs or top_thresholds.mem_blacklist.include?(a.command)}
        mregs_list = mregs_list[0, top_n]

        mem_list   = proc_sums.sort{|a, b| b.mem <=> a.mem}
        mem_list   = mem_list.reject{|a| a.mem <= top_thresholds.mem or top_thresholds.mem_blacklist.include?(a.command)}
        mem_list   = mem_list[0, top_n]

        purg_list  = proc_sums.sort{|a, b| b.purg <=> a.purg}
        purg_list  = purg_list.reject{|a| a.purg <= top_thresholds.purg or top_thresholds.mem_blacklist.include?(a.command)}
        purg_list  = purg_list[0, top_n]

        cmprs_list  = proc_sums.sort{|a, b| b.cmprs <=> a.cmprs}
        cmprs_list  = cmprs_list.reject{|a| a.cmprs <= top_thresholds.cmprs or top_thresholds.mem_blacklist.include?(a.command)}
        cmprs_list  = cmprs_list[0, top_n]

        total_footprint_list  = proc_sums.sort{|a, b| b.total_footprint <=> a.total_footprint}
        total_footprint_list  = total_footprint_list.reject{|a| a.total_footprint <= top_thresholds.mem or top_thresholds.mem_blacklist.include?(a.command)}
        total_footprint_list  = total_footprint_list[0, top_n]

        kprvt_list = proc_sums.sort{|a, b| b.kprvt <=> a.kprvt}
        kprvt_list = kprvt_list.reject{|a| a.kprvt <= top_thresholds.kprvt or top_thresholds.mem_blacklist.include?(a.command)}
        kprvt_list = kprvt_list[0, top_n]

        ports_list = proc_sums.sort{|a, b| b.ports <=> a.ports}
        ports_list = ports_list.reject{|a| a.ports <= top_thresholds.ports or top_thresholds.mem_blacklist.include?(a.command)}
        ports_list = ports_list[0, top_n]

        return TopParseResults.new(cpu_list, idlew_list, power_list,
                                   rprvt_list, rshrd_list, rsize_list,
                                   vprvt_list, vsize_list, mregs_list,
                                   mem_list, purg_list, kprvt_list,
                                   ports_list, cmprs_list, total_footprint_list)
    end

    def Top.parse(path, top_thresholds)
        full_text = File.read(path) # Cleanup - use a statemachine instead
        full_text = SafeParse.encode_string("Top/line", full_text)
        machine_states = []
        proc_states = []
        tops = full_text.split(/^Processes/)

        tops.each{|top|
            pair = top.split("\n\n")
            if pair.length == 2
                machine_text    = pair[0].split("\n").map{|x| x.strip() }
                machine_states << parse_machine_state(machine_text)
                proc_states    << parse_procs(pair[1].split("\n"))
            end
        }

        return [parse_machine_sum(machine_states), parse_proc_sum(proc_states, top_thresholds)]
    end

    def Top.print_physmem(machine_sum)
        used_mem = SafeParse.byte_to_string(machine_sum.used_mem)
        free_mem = SafeParse.byte_to_string(machine_sum.free_mem)
        puts "Used: #{used_mem} Free: #{free_mem}"

        if machine_sum.swapouts <= 0
            puts GREEN + "The system is not currently paging." + DEFAULT
        elsif machine_sum.swapouts <= 64
            puts GREEN + "The system is not excessively paging - just #{machine_sum.swapouts} pageouts." + DEFAULT
        else
            puts RED + "The system is paging, and has paged out #{machine_sum.swapouts} times during the sysdiagnose." + DEFAULT
        end
    end

    def Top.print_disk(machine_sum)
        read_count  = machine_sum.disk_read
        read_bytes  = SafeParse.byte_to_string(machine_sum.disk_bytes_read)
        write_count = machine_sum.disk_written
        write_bytes = SafeParse.byte_to_string(machine_sum.disk_bytes_written)

        puts "Read from disk #{read_count} times for #{read_bytes}"
        puts "Wrote to disk #{write_count} times for #{write_bytes}"
    end

    def Top.print_network(machine_sum)
        read_count  = machine_sum.network_in
        read_bytes  = SafeParse.byte_to_string(machine_sum.network_bytes_in)
        write_count = machine_sum.network_out
        write_bytes = SafeParse.byte_to_string(machine_sum.network_bytes_out)

        puts "Received from network #{read_count} times for #{read_bytes}"
        puts "Sent to network #{write_count} times for #{write_bytes}"
    end

    # columns is an array of triples of the following type:
    # (string, (Top.App Array), (Top.app -> string))
    # The first is a string which is the title of the metric being printed
    # The second is the input array which is sorted by the required metric
    # and clipped to the desired threshold.
    # Third is a lambda that projects the metric to be printed out of a Top.app
    # and formats it as a string. print_columns will justify the string as required.
    def Top.print_columns(columns)
        int_width = 8
        str_width = 16

        headers = columns.map{|f|
            title = f[0]
            [title.rjust(int_width), "PID".rjust(int_width), "COMMAND".ljust(str_width)].join(" ")
        }
        separators = headers.map{|h| VSEP * h.length}

        header    = headers.join(HSEP)
        separator = separators.join(HSEP)

        puts("")
        puts(header)
        puts(separator)
        
        top_n = 0
        columns.each { |c|
            if c[1].length > top_n
                top_n = c[1].length
            end
        }

        for i in 0...top_n
            ents = []
            have_something = false
            columns.each_index{|j|
                c    = columns[j]
                list = c[1]
                proj = c[2]
                if i < list.length
                    proc = list[i]
                    ents << [proj.call(proc).rjust(int_width), proc.pid.to_s.rjust(int_width),
                             proc.command.ljust(str_width)].join(" ")
                    have_something = true
                else
                    ents << " " * headers[j].length
                end
            }

            if have_something
                puts ents.join(HSEP)
            else
                puts ""
                return
            end
        end

        puts ""
        return
    end
    
    def Top.print_cpu(results)
        column_cpu   = ["CPU"  , results.cpu_list  , lambda {|p| SafeParse.float_to_string(p.cpu)}]
        column_idlew = ["IDLEW", results.idlew_list, lambda {|p| p.idlew.to_s}]
        column_power = ["POWER", results.power_list, lambda {|p| SafeParse.float_to_string(p.power)}]
        
        columns = [column_cpu, column_idlew, column_power].reject{|c| c[1].length == 0}
        Top.print_columns(columns)
    end
    
    def Top.print_threads(results)
        if results.cpu_list.length > 0
            Top.print_columns([["THREADS", results.cpu_list, lambda {|p| p.th}]])
        end
    end
    
    def Top.print_mem_summary(results)
        column_mem   = ["MEM"  , results.mem_list  , lambda {|p| SafeParse.byte_to_string(p.mem)}]
        column_purg  = ["CMPRS", results.cmprs_list, lambda {|p| SafeParse.byte_to_string(p.cmprs)}]
        column_rprvt = ["RPRVT", results.rprvt_list, lambda {|p| SafeParse.byte_to_string(p.rprvt)}]
        column_rshrd = ["RSHRD", results.rshrd_list, lambda {|p| SafeParse.byte_to_string(p.rshrd)}]
        column_rsize = ["RSIZE", results.rsize_list, lambda {|p| SafeParse.byte_to_string(p.rsize)}]
        
        columns = [column_mem, column_purg, column_rprvt, column_rshrd, column_rsize].reject{|c| c[1].length == 0}
        Top.print_columns(columns)
    end
    
    def Top.print_mem_verbose(results)
        column_vprvt = ["VPRVT", results.vprvt_list, lambda {|p| SafeParse.byte_to_string(p.vprvt)}]
        column_vsize = ["VSIZE", results.vsize_list, lambda {|p| SafeParse.byte_to_string(p.vsize)}]
        column_cmprs = ["PURG" , results.purg_list , lambda {|p| SafeParse.byte_to_string(p.purg)}]
        column_mregs = ["MREGS", results.mregs_list, lambda {|p| p.mregs.to_s}]
        column_kprvt = ["KPRVT", results.kprvt_list, lambda {|p| SafeParse.byte_to_string(p.kprvt)}]
        column_ports = ["PORTS", results.ports_list, lambda {|p| p.ports.to_s}]
        
        columns = [column_vprvt, column_vsize, column_cmprs, column_mregs, column_kprvt, column_ports].reject{|c| c[1].length == 0}
        if columns.length > 3
            Top.print_columns(columns[0...3])
            Top.print_columns(columns[3...columns.length])
            else
            Top.print_columns(columns)
        end
    end

    def Top.mini_mem(results, output_dict)
        if results.mem_list.length > 0
            output_dict.add("top_mem_proc", results.mem_list[0].command)
            output_dict.add("top_mem_bytes", results.mem_list[0].mem)
        end
        
        if results.cmprs_list.length > 0
            output_dict.add("top_cmrps_proc", results.cmprs_list[0].command)
            output_dict.add("top_cmprs_bytes", results.cmprs_list[0].cmprs)
        end

        if results.total_footprint_list.length > 0
            output_dict.add("top_footprint_proc", results.total_footprint_list[0].command)
            output_dict.add("top_footprint_bytes", results.total_footprint_list[0].total_footprint)
        end
    end

    def Top.mini_energy(results, output_dict)
        if results.cpu_list.length > 0
            output_dict.add("top_cpu_proc", results.cpu_list[0].command)
            output_dict.add("top_cpu_percent", results.cpu_list[0].cpu)
        end

        if results.power_list.length > 0
            output_dict.add("top_energy_proc", results.power_list[0].command)
            output_dict.add("top_energy_score", results.power_list[0].power)
        end
    end
    
    def Top.mini_machine(machine_sum, output_dict)
        output_dict.add("total_bytes_used", machine_sum.used_mem)
        output_dict.add("total_bytes_free", machine_sum.free_mem)
        output_dict.add("total_swapouts", machine_sum.swapouts)
        output_dict.add("total_disk_bytes_read", machine_sum.disk_bytes_read)
        output_dict.add("total_disk_bytes_written", machine_sum.disk_bytes_written)
        output_dict.add("total_network_bytes_in", machine_sum.network_bytes_in)
        output_dict.add("total_network_bytes_out", machine_sum.network_bytes_out)
        output_dict.add("total_cpu_percent_user", machine_sum.cpu_user)
        output_dict.add("total_cpu_percent_system", machine_sum.cpu_system)
        output_dict.add("total_cpu_percent_idle", machine_sum.cpu_idle)
    end
end

################################################################################
########## SysTriage top-level #################################################
################################################################################

module SysTriage
    def SysTriage.print_usage()
        puts "Description:"
        puts "systriage is a first-level triage tool that works by post-processing the information in sysdiagnose bundles.\n"
        puts ""
        puts "Usage:"
        puts "systriage [options] <sysdiagnose_bundle>"
        puts ""
        puts "<sysdiagnose_bundle> may be a path to:"
        puts "- a sysdiagnose directory corresponding to an extracted sysdiagnose archive"
        puts "- path to an incomplete sysdiagnose directory"
        puts "We also try to process tmdiagnose bundles, but our summary of top info is questionable."
        puts ""
        puts "run `systriage -h` to explore other command line options"
    end

    TIME_FORMAT_STRING = '(format: YYYY-MM-DD hh:mm:ss)' # For our use to print to the user
    ARG_TIME_FORMAT = '%Y-%m-%d %H:%M:%S'                # For use with the DateTime class
    TOP_TIME_FORMAT = '%Y/%m/%d %H:%M:%S'

    def SysTriage.parse_args(args)
        begin
            options            = {}
            options["cpu"]     = false
            options["memory"]  = false
            options["io"]      = false
            options["history"] = false
            options["start"]   = nil
            options["end"]     = nil
            options["upto"]    = nil
            options["power"]   = false
            options["debug"]   = false
            options["mini"]    = false

            optparse = OptionParser.new do |opts|
                opts.banner = "systriage version #{SYSTRIAGE_VERSION}"

                opts.on('-c', '--cpu', 'Detailed information on CPU consumers',
                        'Applies to current data and incompatible with history modes') do
                    options["cpu"] = true
                end

                opts.on('-m', '--mem', '--memory', 'Detailed information on Memory consumers',
                        'Applies to current data and incompatible with history modes') do
                    options["memory"] = true
                end

                opts.on('-i', '--io', '--disk', 'Detailed information on File System users',
                        'Applies to current data and incompatible with history modes') do
                    options["io"] = true
                end
                
                opts.on('-p', '--power', 'Detailed information on system power usage',
                        'Applies to current data and incompatible with history modes') do
                    options["power"] = true
                end
                
                opts.on('--mini', 'Mini signature of the sysdiagnose',
                        'incompatible with all other modes') do
                    options["mini"] = true
                end
                        
                opts.on('-d', '--debug', 'Detailed logging of non-fatal parse errors',
                        'Non-fatal parse errors usually indicate that legacy data is not present in the sysdiagnose') do
                    options["debug"] = true
                end
                
                opts.on('-H', '--history', 'Analyze historical data using systemstats',
                        'For microstackshots, you need to additionally specify -s or -A.') do
                    options["history"] = true
                end

                opts.on('-s', '--start_history [TIME]',
                        'Analyze historical data starting at TIME ' + TIME_FORMAT_STRING,
                        'This feature requires systemstats and microstackshot data.') do |time|
                    options["start"] = SafeParse.parse_time("opts/start_history", time, ARG_TIME_FORMAT)
                    if options["start"] == nil
                        $stderr.puts "--start_history: Invalid time argument. Must match " + TIME_FORMAT_STRING
                        exit
                    end
                end

                opts.on('-e', '--end_history [TIME]',
                        'Analyze historical data ending at TIME ' + TIME_FORMAT_STRING,
                        'This feature requires systemstats and microstackshot data.') do |time|
                    options["end"] = SafeParse.parse_time("opts/end_history", time, ARG_TIME_FORMAT)
                    if options["end"] == nil
                        $stderr.puts "--end_history: Invalid time argument. Must match " + TIME_FORMAT_STRING
                        exit
                    end
                end

                opts.on('-A', '--history_up_to N',
                        'Analyze historical data starting N seconds before the sysdiagnose',
                        'This option conflicts with -s and -e.') do |n|
                    if n =~ /^(\d+)$/
                        options["upto"] = $1.to_i()
                    else
                        $stderr.puts "--history_up_to: Invalid number of seconds"
                    end
                end

                opts.on_tail('-h', '--help', 'Display this screen') do
                    SysTriage.print_usage()
                    $stderr.puts(opts)
                    exit
                end

                opts.on_tail('-v', '--version', 'Display systriage version information') do
                    $stderr.puts(opts.banner)
                    exit
                end
            end.parse!(args)
            
            path = args.join(" ")
            if path == nil
                SysTriage.print_usage()
                exit
            end
            
            return [path, options]
        rescue OptionParser::InvalidOption => e
            $stderr.puts "systriage: illegal option "
            SysTriage.print_usage()
            exit
        end
    end

    def SysTriage.get_path(path)
        if path == ""
            $stderr.puts "No path supplied"
            return [nil, false]
        elsif Dir.exists?(path)
#            $stderr.puts "#{path} is a directory -- assuming it came from sysdiagnose or tmdiagnose"
            return [path, false]
        elsif File.exists?(path) and path.end_with?("tar.gz")
            # Try to safely untar. Use -k to prevent overwriting.
            # tar is documented to try and strip the leading / when extracting,
            # which should protect against polluting random parts of the filesystem.
            # tar is documented to not follow symlinks by default.
            # And lastly, we do not write or execute anything in the extracted dir.
            $stderr.puts "#{path} looks like a tarball. Trying to extract it to get a sysdiagnose"
            basename = File.basename(path, ".tar.gz")
            mktemp_command = ["/usr/bin/mktemp", "-d", "/tmp/#{basename}_XXXXXX"]
            temp_dir = nil
            
            IO.popen(mktemp_command){|outstream|
                output = outstream.readlines()
                if output.count == 1
                    temp_dir = output[0].strip()
                end
            }
            
            if temp_dir != nil and Dir.exists?(temp_dir)
                extract_command = ["/usr/bin/tar", "-x", "-k", "-f", path, "-C", temp_dir, "--strip", "1"]
                system(*extract_command)
                return [temp_dir, true]
            else
                $stderr.puts "Unable to get temp directory for safe extraction of the tarball"
                return [nil, false]
            end
        else
            $stderr.puts "Invalid path"
            return [nil, false]
        end
    end

    def SysTriage.section_separator(heading, outstream=$stdout)
        separator = "*"*70
        outstream.puts "\n\n"
        outstream.puts separator
        outstream.puts heading
        outstream.puts separator
        outstream.puts "\n"
    end

    def SysTriage.subsection_separator(heading, outstream=$stdout)
        separator = "*"*50
        outstream.puts "\n"
        outstream.puts heading
        outstream.puts separator
        outstream.puts "\n"
    end

    #For compatibility with tmdiagnose
    def SysTriage.find_sys_state(path)
        sys_state_path = `find "#{path}/" -type d -name "System State *" -print 2>/dev/null | head -1`.chomp.chomp('/')
        if (sys_state_path == "")
            sys_state_path = `find "#{path}/" -type d -name "system_state_" -print 2>/dev/null | head -1`.chomp.chomp('/')
            if (sys_state_path == "")
                return path
            end
        end
        return sys_state_path
    end

    def SysTriage.get_powermetrics(path, detailed)
        sys_state_path = SysTriage.find_sys_state(path)
        pmetrics_path = "#{sys_state_path}/powermetrics.txt"
        if (File.exists?(pmetrics_path))
            return PowerUsage.parse_all(pmetrics_path, detailed)
        else
            ErrorLog.report("Could not find powermetrics output")
            return nil
        end
    end

    def SysTriage.get_top_path(path)
        sys_state_path = SysTriage.find_sys_state(path)
        top_path = "#{sys_state_path}/top.txt"
        if (not File.exists?(top_path))
            top_path = "#{sys_state_path}/top.log"
            if (not File.exists?(top_path))
                ErrorLog.report("Could not find top output")
                return nil
            end
        end
        return top_path
    end

    def SysTriage.get_fs_usage(path, spindump_path, detailed, io_blacklist, top_n)
        sys_state_path = SysTriage.find_sys_state(path)
        fs_usage_path = "#{sys_state_path}/fs_usage.txt"
        if (not File.exists?(fs_usage_path))
            fs_usage_path = "#{sys_state_path}/fs_usage.log"
            if (not File.exists?(fs_usage_path))
                ErrorLog.report("Could not find fs_usage output")
                return nil
            end
        end

        thread_to_process_map = {}
        if (spindump_path != nil)
            thread_to_process_map = Spindump.make_thread_to_process_map(spindump_path)
        end

        return FSUsage.parse(fs_usage_path, thread_to_process_map, detailed, io_blacklist, top_n)
    end

    def SysTriage.get_spindump_path(path)
        spindump_path = "#{SysTriage.find_sys_state(path)}/spindump.txt"
        if (not File.exists?(spindump_path))
            ErrorLog.report("Could not find spindump")
            return nil
        else
            return spindump_path
        end
    end

    def SysTriage.get_allmemory_path(path)
        allmemory_path = "#{SysTriage.find_sys_state(path)}/allmemory.txt"
        if (not File.exists?(allmemory_path))
            fs_usage_path = "#{path}/allmemory.txt"
            return nil
        else
            return allmemory_path
        end
    end

    def SysTriage.get_sysprofile_path(path)
        sysprofile_path = "#{SysTriage.find_sys_state(path)}/system_profiler.spx"
        if (not File.exists?(sysprofile_path))
            sysprofile_path = "#{SysTriage.find_sys_state(path)}/system profile.spx"
            if (not File.exists?(sysprofile_path))
                ErrorLog.report("Could not find sysprofile.spx")
                return nil
            end
        end

        return sysprofile_path
    end

    class SysTriageHeader
        attr_accessor :os_version, :hw_version, :disk_type, :phys_mem
        
        def initialize(*args)
            @os_version = args[0]
            @hw_version = args[1]
            @disk_type  = args[2]
            @phys_mem   = args[3]
        end
    end

    def SysTriage.parse_header(spindump_path, sysprofile_path)
        os_version = "Unknown"
        hw_version = "Unknown"
        if (spindump_path != nil)
            file = File.open(spindump_path, SYSDIAGNOSE_ENCODING)

            file.each{|line|
                case line
                    when /^OS Version:(.*)$/
                        os_version = SafeParse.to_string("Spindump/OSVersion", $1)
                    when /^Hardware model:(.*)$/
                        hw_version = SafeParse.to_string("Spindump/HWVersion", $1)
                end

                if os_version != "Unknown" and hw_version != "Unknown"
                    break
                end
            }

            file.close()
        end

        # Find out Memory information
        disk_type = "Unknown"
        phys_mem  = "Unknown"
        if (sysprofile_path != nil)
            file = File.open(sysprofile_path, SYSDIAGNOSE_ENCODING)
            state = ""

            file.each{|line|
                case line
                    when /physical_memory/
                        state = "phys_mem"
                    when /spsata_medium_type/
                        state = "disk_type"
                    else
                        case state
                            when "phys_mem"
                                if line =~ /<string>(.+)<\/string>/
                                    phys_mem = $1
                                end
                            when "disk_type"
                                if line =~ /<string>(.+)<\/string>/
                                    disk_type = $1
                                end
                        end
                        state = ""
                end

                if disk_type != "Unknown" and phys_mem != "Unknown"
                    break
                end
            }

            file.close()
        end
        
        return SysTriageHeader.new(os_version, hw_version, disk_type, phys_mem)
    end

    def SysTriage.print_header(header)
        left_size = 12
        puts "OS Version".rjust(left_size) + HSEP + header.os_version
        puts "Machine".rjust(left_size)    + HSEP + header.hw_version
        puts "Disk".rjust(left_size) + HSEP + header.disk_type
        puts "RAM".rjust(left_size)  + HSEP + header.phys_mem
    end

    # This is the main function for the scripts execution
    def SysTriage.analyze_now(path, options)
        cpu_blacklist = ["spindump", "top", "fs_usage", "trace", "sysdiagnose"]
        mem_blacklist = ["spindump", "top", "fs_usage", "trace", "sysdiagnose", "kernel_task"]
        io_blacklist  = ["spindump", "top", "fs_usage", "trace", "sysdiagnose"]

        top_thresholds =
            Top::ReportingThreshold.new(
                                        1.0,      #CPU
                                        1,        #IDLEW
                                        1.0,      #POWER
                                        MEGABYTE, #RPRVT
                                        MEGABYTE, #RSHRD
                                        MEGABYTE, #RSIZE
                                        MEGABYTE, #VPRVT
                                        MEGABYTE, #VSIZE
                                        0,        #MREGS
                                        MEGABYTE, #MEM
                                        MEGABYTE, #PURG
                                        KILOBYTE, #KPRVT
                                        0,        #PORTS
                                        MEGABYTE, #CMPRS
                                        cpu_blacklist,
                                        mem_blacklist,
                                        5         #TOP_N, 0 implies no limit
                                        )

        # Need top output for all tasks... collect and save it now.
        (top_machine, top_procs) = [nil, nil]
        top_path = SysTriage.get_top_path(path)
        if (top_path != nil)
            (top_machine, top_procs) = Top.parse(top_path, top_thresholds)
        end

        spindump_path   = SysTriage.get_spindump_path(path)
        sysprofile_path = SysTriage.get_sysprofile_path(path)
        fs_usage        = SysTriage.get_fs_usage(path, spindump_path, options["io"], io_blacklist, 5)
        powermetrics    = SysTriage.get_powermetrics(path, options["power"])
        header          = SysTriage.parse_header(spindump_path, sysprofile_path)

        SysTriage.section_separator("Hardware and Software Version (from system_profiler.spx)")
        print_header(header)

        SysTriage.section_separator("Machine State (see top.txt for raw data)")
        if (top_machine != nil)
            Top.print_physmem(top_machine)
            Top.print_disk(top_machine)
            Top.print_network(top_machine)
        end

        SysTriage.section_separator("CPU Usage (see top.txt and spindump.txt for raw data)\nRun `systriage -c path` for more information.")
        if (top_procs != nil)
            Top.print_cpu(top_procs)
        end

        SysTriage.section_separator("Memory Usage (see top.txt for raw data)\nRun `systriage -m path` for more information.")
        if (top_procs != nil)
            Top.print_mem_summary(top_procs)
        end

        SysTriage.section_separator("IO Activity (see fs_usage.txt for raw data)\nRun `systriage -i path` for more information.")
        if (fs_usage != nil)
            FSUsage.print_summary(fs_usage)
        end
        
        SysTriage.section_separator("Power usage (see powermetrics.txt for raw data)\nRun `systriage -p path` for more information.")
        if (powermetrics != nil)
            PowerUsage.print_summary(powermetrics)
        end
        
        if options["cpu"]
            SysTriage.section_separator("Detailed CPU Usage Information")
            if (spindump_path != nil)
                Top.print_threads(top_procs)
                Spindump.print_summary(spindump_path, top_procs.cpu_list)
            end
        end

        if options["memory"]
            SysTriage.section_separator("Detailed Memory Usage Information")
            if (top_procs != nil)
                Top.print_mem_verbose(top_procs)
            end

            SysTriage.subsection_separator("Heaps (see heap.txt files)")
            Heap.print_summary(path, nil)

            SysTriage.subsection_separator("Leaks (see leaks.txt files)")
            Leaks.print_summary(path)

            allmemory_path = SysTriage.get_allmemory_path(path)
            if (allmemory_path != nil)
                SysTriage.subsection_separator("All Memory (see allmemory.txt files)")
                if top_procs.mem_list.length > 0
                    Allmemory.print_summary(allmemory_path, top_procs.mem_list)
                else
                    Allmemory.print_summary(allmemory_path, top_procs.rprvt_list)
                end
            end
        end

        if options["io"]
            SysTriage.section_separator("Detailed IO Activity Information")
            if (fs_usage != nil)
                FSUsage.print_verbose(fs_usage)
            end
        end

        if options["power"]
            SysTriage.section_separator("Detailed Power Usage Information")
            if (powermetrics != nil)
                PowerUsage.print_details(powermetrics)
            end
        end

        return
    end
    
    # Mini mode for feedback assistant
    def SysTriage.analyze_mini(path)
        cpu_blacklist = ["spindump", "top", "fs_usage", "trace", "sysdiagnose"]
        mem_blacklist = ["spindump", "top", "fs_usage", "trace", "sysdiagnose", "kernel_task"]
        io_blacklist  = ["spindump", "top", "fs_usage", "trace", "sysdiagnose", "kernel_task", "launchd"]

        top_thresholds =
            Top::ReportingThreshold.new(
                                        5.0,      #CPU
                                        5,        #IDLEW
                                        5.0,      #POWER
                                        10 * MEGABYTE, #RPRVT
                                        10 * MEGABYTE, #RSHRD
                                        10 * MEGABYTE, #RSIZE
                                        10 * MEGABYTE, #VPRVT
                                        GIGABYTE, #VSIZE
                                        100,      #MREGS
                                        10 * MEGABYTE, #MEM
                                        10 * MEGABYTE, #PURG
                                        MEGABYTE, #KPRVT
                                        100,      #PORTS
                                        MEGABYTE, #CMPRS
                                        cpu_blacklist,
                                        mem_blacklist,
                                        1         #TOP_N, 0 implies no limit
                                        )

        # Need top output for all tasks... collect and save it now.
        (top_machine, top_procs) = [nil, nil]
        top_path = SysTriage.get_top_path(path)
        if (top_path != nil)
            (top_machine, top_procs) = Top.parse(top_path, top_thresholds)
        end
        
        fs_usage     = SysTriage.get_fs_usage(path, nil, false, io_blacklist, 1)
        powermetrics = SysTriage.get_powermetrics(path, false)
        output_dict  = MiniModeResults.new("perf")
        
        if (top_procs != nil)
            Top.mini_machine(top_machine, output_dict)
            Top.mini_energy(top_procs, output_dict)
            Top.mini_mem(top_procs, output_dict)
        end
        
        if (fs_usage != nil)
            FSUsage.mini(fs_usage, output_dict)
        end
        
        if (powermetrics != nil)
            PowerUsage.mini(powermetrics, output_dict)
        end

        output_dict.pretty_generate()
        return
    end
    
    def SysTriage.get_pmset_path(path)
        pmset_log_path = "#{path}/pmset_everything.txt"

        if not File.exists?(pmset_log_path)
            pmset_log_path = "#{path}/pmset.log"
            if not File.exists?(pmset_log_path)
                pmset_log_path = nil
                ErrorLog.report("Power Management logs not found")
                return nil
            end
        end

        return pmset_log_path
    end

    def SysTriage.get_microstackshot_path(path)
        microstackshot_path = "#{path}/microstackshots"

        if not File.exists?(microstackshot_path)
            microstackshot_path = nil
            ErrorLog.report("Microstackshots not captured by sysdiagnose." +
                            "sysdiagnose gathered on OS Version < 10.9?")
        end

        if not File.exists?(SPINDUMP_PATH)
            microstackshot_path = nil
            ErrorLog.report("spindump not available on triage system???")
        end

        return microstackshot_path
    end

    def SysTriage.get_log_path(path)
        log_dir_path     = "#{path}/logs"
        systemstats_path = nil
        system_log_path  = nil
        dsc_path         = nil

        if not File.exists?(log_dir_path)
            ErrorLog.report("log directory not found")
            return [nil, nil, nil]
        end

        systemstats_path = "#{log_dir_path}/systemstats"
        if not File.exists?(systemstats_path)
            systemstats_path = nil
            ErrorLog.report("systemstats not captured by sysdiagnose." +
                            "sysdiagnose gathered on OS Version < 10.9?")
        end

        if not File.exists?(SYSTEMSTATS_PATH)
            systemstats_path = nil
            ErrorLog.report("systemstats not available on triage system." +
                            "Triage OS Version < 10.9?")
        end

        system_log_path = "#{log_dir_path}/system.log"
        if not File.exists?(system_log_path)
            system_log_path = nil
            ErrorLog.report("system.log not found")
        end

        dsc_path = "#{log_dir_path}/olddsc"
        if not File.exists?(dsc_path)
            dsc_path = nil
            ErrorLog.report("DSC map not captured by sysdiagnose" +
                            "sysdiagnose gathered on OS Version < 10.9?")
        end

        return [systemstats_path, system_log_path, dsc_path]
    end

    HISTORY_UPTO_FATAL_ERROR = "Fatal error while processing -A (--history_upto) option. Please try -s instead"

    def SysTriage.get_history_window(path, options)
        if (options["upto"])
            top_path = get_top_path(path)
            if top_path == nil
                ErrorLog.exit_verbose(HISTORY_UPTO_FATAL_ERROR)
            end

            file = File.open(top_path, SYSDIAGNOSE_ENCODING)
            file.gets()
            current_time_str = file.gets()
            file.close()

            if (current_time_str == nil)
                ErrorLog.exit_verbose(HISTORY_UPTO_FATAL_ERROR)
            end

            current_time = SafeParse.parse_time("top/current_time", current_time_str, TOP_TIME_FORMAT)
            if current_time == nil
                ErrorLog.exit_verbose(HISTORY_UPTO_FATAL_ERROR)
            end

            # current_time is measured in days. upto is measured in seconds.
            # Express upto as a fraction of a day using Rational.
            return [current_time - Rational(options["upto"], SECONDS_IN_DAY), options["end"]]
        else
            return [options["start"], options["end"]]
        end
    end

    def SysTriage.analyze_history(path, options)
        (systemstats_path, system_log_path, dsc_path) = get_log_path(path)
        pmset_log_path         = get_pmset_path(path)
        microstackshot_path    = get_microstackshot_path(path)
        (start_time, end_time) = get_history_window(path, options)

        if systemstats_path != nil
            command = [SYSTEMSTATS_PATH, "-f", path]

            if start_time != nil
                command += ["-s", start_time.strftime(ARG_TIME_FORMAT)]
            end

            if end_time != nil
                command += ["-e", end_time.strftime(ARG_TIME_FORMAT)]
            end

            system(*command)
        end

        # Safeguard: avoid symbolicating the entire microstackshot database. Require -s to be supplied.
        if microstackshot_path != nil and start_time != nil and dsc_path != nil
            command = [SPINDUMP_PATH, "-microstackshots", "-microstackshots_datastore",
                microstackshot_path, "-microstackshots_dsc_path", dsc_path, "-dsymForUUID",
                "-microstackshots_starttime", start_time.strftime(ARG_TIME_FORMAT)]

            if end_time != nil
                command += ["-microstackshots_endtime", end_time.strftime(ARG_TIME_FORMAT)]
            end

            $stderr.puts "Symbolicating microstackshots for the specified interval."
            $stderr.puts "This may take a while..."
            system(*command)
        end

        # Needs to be implemented extraction of other logs!
        return
    end

    def SysTriage.analyze(args)
        (path_str, options) = SysTriage.parse_args(args)
        history_mode = false
        current_mode = false
        mini_mode    = false
        
        if options["mini"] == true
            mini_mode = true
        end
        
        if options["cpu"] or options["memory"] or
            options["io"] or options["power"]
            current_mode = true
        end
        
        if options["history"] or options["start"] != nil or
            options["end"] != nil or options["upto"] != nil
            history_mode = true
        end
        
        if (mini_mode and current_mode) or
            (current_mode and history_mode) or
            (history_mode and mini_mode)
            $stderr.puts "Incompatible options: mini mode, history mode and current mode all exclude each other"
            exit
        end

        if options["upto"] != nil and (options["start"] != nil or options["end"] != nil)
            $stderr.puts "Incompatible options: --history_up_to conflicts with separate start and end timestamps"
            exit
        end
        
        #current mode is to be default
        if !mini_mode and !current_mode and !history_mode
            current_mode = true
        end

        (path, should_delete) = SysTriage.get_path(path_str)
        if path == nil
            $stderr.puts "Invalid path to sysdiagnose: #{path_str}"
            exit
        end
        
        if history_mode
            SysTriage.analyze_history(path, options)
        elsif current_mode
            SysTriage.analyze_now(path, options)
        elsif mini_mode
            SysTriage.analyze_mini(path)
        end
        
        if should_delete
            delete_command = ["/bin/rm", "-rf", path]
            system(*delete_command)
        end
        
        if options["debug"]
            SysTriage.section_separator("End systriage", $stderr)
            ErrorLog.exit_verbose("No fatal errors.")
        else
#            $stderr.puts "No fatal errors. Run with --debug for log of non-fatal parse errors"
        end

        return 0
    end
end


if (__FILE__ == $0)
    SysTriage.analyze(ARGV)
end
