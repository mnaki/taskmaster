class JobManager

    def initialize(config)
        @jobs = {}
        config.each do |c|
            @jobs[c["name"]] = []
            c["processes"].times do
                @jobs[c["name"]] << Job.new(c)
            end
        end

        @line = ""
        @last_line = ""
    end
    
    def status
        @jobs.each do |name, processes|
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
                            puts "EXCEPTION: #{e.inspect}"
                            puts "BBB MESSAGE: #{e.message}"
                            Process.exit
                        end
                    end
                    p
                end
            end
        end.compact
    end

    def start_job(job_name = nil)
        each(job_name) { |p| p.start }
    end

    def stop_job(job_name = nil)
        each(job_name) { |p| p.soft_stop }
    end
    
    def force_stop_job(job_name = nil)
        each(job_name) { |p| p.force_stop }
    end
    
    def restart_job(job_name = nil)
        each(job_name) { |p| p.restart }
    end

    def update_job(job_name = nil, config)
        each(job_name) { |p|
            if p.config != config
                p.config = config
                scale_job(job_name, config["processes"])
            end
        }
    end

    def set_config_var(job_name, var, val)
        each(job_name) do |j|
            j.config[var] = val
        end
    end

    def save_config
        new_config = []
        @jobs.each do |name, processes|
            new_config << processes.first.config
        end
        File.open("config.yml", 'w') do |file|
            file.write(new_config.to_yaml)
        end
    end

    def reload
        conf = YAML.load_file('config.yml')
        conf.each do |c|
            update_job(c["name"], c)
        end
    end

    def scale_job(job_name, num)
        
        if num == 0
            return
        end

        @jobs.each do |name, processes|
            processes_to_remove = []
            additional_process_num = num - processes.size

            if additional_process_num > 0
                additional_process_num.times do
                    processes << Job.new(processes.first.config)
                end
            elsif additional_process_num < 0
                processes_to_remove = processes.pop(-(additional_process_num))
            end

            processes_to_remove.each do |process|
                process.force_stop
            end
        end
    end

    def read_line
        print '#> '
        @line = STDIN.gets&.chomp&.strip || ""
        if @line == "!!"
            @line = @last_line
        end
        process_line
        @last_line = @line if @line != "!!"
    end

    def process_line
        args = @line.chomp.strip.split " "
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
          @line = "'#{@line}' is not a valid command"
        end
    end

end
