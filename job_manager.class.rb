require 'yaml'
require 'logger'

class JobManager

    def initialize(config)
        @log = Logger.new('log.txt') 
        @log.info "Initializing JobManager"
        @jobs = {}
        config.each do |c|
            @log.info "Creating job #{c['name']}"
            @jobs[c["name"]] = []
            c["processes"].times do
                @log.info "Adding new process to job #{c['name']}"
                @jobs[c["name"]] << Job.new(c)
            end
        end

        @line = ""
        @last_line = ""
    end
    
    def status
        @jobs.each do |name, processes|
            @log.info "Printing status for #{name}"
            puts "[Job = #{name}]\n"
            puts "\n# Config\n"
            puts processes.first.config_to_s
            puts "\n# Processes\n"
            puts processes.map(&:to_s)
            puts "\n\n"
        end
    end

    def each(job_name = nil)
        @jobs.flat_map do |name, processes|
            processes.flat_map do |p|
                if (job_name.nil?) || (p.config["name"] == job_name)
                    Thread.new do
                        begin
                            yield p
                        rescue Exception => e
                            @log.error "Error #{e.message}"
                        end
                    end
                    p
                end
            end
        end.compact
    end

    def start_job(job_name = nil)
        @log.info "start_job #{job_name}"
        each(job_name) { |p| p.start }
    end

    def stop_job(job_name = nil)
        @log.info "stop_job #{job_name}"
        each(job_name) { |p| p.soft_stop }
    end
    
    def force_stop_job(job_name = nil)
        @log.info "force_stop_job #{job_name}"
        each(job_name) { |p| p.force_stop }
    end
    
    def restart_job(job_name = nil)
        @log.info "restart_job #{job_name}"
        each(job_name) { |p| p.restart }
    end

    def update_job(job_name = nil, config)
        @log.info "update_job #{job_name}"
        if @jobs[job_name].nil?
            @log.info "New job detected (#{job_name}). Adding..."
            @jobs[job_name] = [Job.new(config)]
        else
            @log.info "Job already exists (#{job_name}). Updating according to changes..."
            each(job_name) do |p|
                if p.config != config
                    @log.info "Change detected. Updating"
                    p.config = config
                    @log.info "#{config.to_s}"
                    scale_job(job_name, config["processes"])
                else
                    @log.info "Identical config. Not updating"
                end
            end
        end
    end

    def set_config_var(job_name, var, val)
        @log.info "set_config_var #{job_name}, (#{var} = #{val})"
        each(job_name) do |j|
            j.config[var] = val
        end
    end

    def save_config
        @log.info "save_config"
        new_config = []
        @jobs.each do |name, processes|
            new_config << processes.first.config
        end
        File.open("config.yml", 'w') do |file|
            file.write(new_config.to_yaml)
        end
    end

    def reload
        @log.info "reload"
        conf = YAML.load_file('config.yml')
        conf.each do |c|
            update_job(c["name"], c)
        end
    end

    def scale_job(job_name, num)
        @log.info "scale_job #{job_name}, #{num}"
        num = num.to_i
        
        if num == 0
            return
        end

        @jobs.each do |name, processes|
            processes_to_remove = []
            additional_process_num = num - processes.size

            if additional_process_num > 0
                @log.info "Scaling up job by #{additional_process_num} additional processes..."
                additional_process_num.times do
                    @log.info "...Spawning"
                    processes << Job.new(processes.first.config)
                end
            elsif additional_process_num < 0
                @log.info "Scaling down job by removing #{-additional_process_num} processes..."
                processes_to_remove = processes.pop(-(additional_process_num))
            end

            processes_to_remove.each do |process|
                @log.info "...Killing"
                process.force_stop
            end
        end
    end

    def read_line
        @log.info "Reading line..."
        print '#> '
        @line = STDIN.gets&.chomp&.strip || ""
        @log.info "line = #{@line}"
        if @line == "!!"
            @line = @last_line
        end
        process_line
        @last_line = @line if @line != "!!"
    end

    def process_line
        @log.info "Processing line"
        args = @line.chomp.strip.split " "
        @log.info "Args [#{args.join(', ')}]"
        case args[0]
        when "start"
            start_job(args[1])
        when "stop"
            stop_job(args[1])
        when "kill"
            force_stop_job(args[1])
        when "restart"
            restart_job(args[1])
        when "scale"
            scale_job(args[1], args[2].to_i)
        when "set"
            set_config_var(args[1], args[2], args[3])
        when "save"
            save_config
        when "reload"
            reload
        when "status"
            status
        else
            @log.info "Invalid command"
            @line = "'#{@line}' is not a valid command"
        end
    end

end
