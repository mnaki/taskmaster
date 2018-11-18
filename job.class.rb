require 'logger'

class Job
    
    attr_accessor(
        :pid,
        :config,
        :thread,
        :exit_status,
        :process,
        :failures
    )

    def initialize(config)
        @log = Logger.new("log.#{config['name']}.txt") 
        @log.info "Initializing Job #{config['name']}"

        @config = config

        @thread = nil
        @process = nil

        @failures = 0
        @pid = nil
        @exit_status = nil
        @state = nil

        if config["autostart"] == true
            @log.info "Autostart enabled"
            Thread.new do
                start
            end
        end
    end

    def is_running?
        if @pid
            Process.kill(0, @pid)
        end
    rescue Errno::ESRCH
        false
    end

    def is_expected_exit?
        if @state == "abandonned"
            false
        elsif @state == "early_exit"
            false
        elsif @state == "terminated"
            true
        elsif @state == "exit" || @state == "exiting"
            true
        elsif @state == "started"
            @config["expected_status"].any? { |c| @exit_status == c }
        end
    end

    def start
        @log.info "Starting process thread"
        @thread = Thread.new do
            begin
                @state = "starting"
                @log.info "Starting"
                sleep @config["start_minimum_time"]
                if is_running?
                    @state = "started"
                    @log.info "Process started successfully"
                end
            rescue Exception => e
                @log.error "Error #{e.message}"
            end
        end
        @pid = Process.fork do
            pid = Process.pid
            @log.info "Fork PID = #{pid}"

            @exit_status = nil

            @log.info "(pid=#{pid}) - Setting env"
            if @config["env"]
                @config["env"].map do |var, val|
                    ENV[var.to_s] = val.to_s
                end
            end

            @log.info "(pid=#{pid}) - Setting stdout"
            $stdout.reopen(@config["stdout"], "w") if @config["stdout"]
            @log.info "(pid=#{pid}) - Setting stdin"
            $stderr.reopen(@config["stderr"], "w") if @config["stderr"]
            
            @log.info "(pid=#{pid}) - Setting working_dir"
            Dir.chdir(@config["working_dir"])

            umask = @config["umask"]
            if umask.kind_of? String
                umask = umask.to_i(8)
            elsif umask.kind_of? Numeric
                umask = umask
            end
            @log.info "(pid=#{pid}) - Setting umask"
            File.umask(umask)

            @log.info "(pid=#{pid}) - Exec'ing"
            exec("bash", "-c", @config["cmd"])
            @log.error "(pid=#{pid}) - Exec failed. Exiting with status 1"
            exit(1)
        end
        @log.info "Waiting for process to finish"
        Process.wait(@pid)
        @log.info "Process finished"
        on_exit
    rescue Exception => e
        @log.error "Error #{e.message}"
    end

    def restart
        @log.info "restart"
        @state = "exiting"
        @thread.exit if @thread
        Process.kill(@config["exit_signal"], @pid) if !@pid.nil?
        Thread.new do
            begin
                sleep @config["exit_timeout"] || 1
                force_stop if is_running?
                @state = "starting"
                start
            rescue Exception => e
                puts "EXCEPTION: #{e.inspect}"
                puts "WWW MESSAGE: #{e.message}"
                Process.exit
            end
        end
    end

    def soft_stop
        @log.info "soft_stop"
        @state = "exiting"
        @thread.exit if @thread
        Process.kill(@config["exit_signal"], @pid) if !@pid.nil?
        Thread.new do
            begin
                sleep @config["exit_timeout"] || 1
                force_stop if is_running?
            rescue Exception => e
                puts "EXCEPTION: #{e.inspect}"
                puts "AAA MESSAGE: #{e.message}"
                Process.exit
            end
        end
    end

    def force_stop
        @log.info "force_stop"
        if !@pid.nil?
            @state = "terminated"
            @thread.exit if @thread
            Process.kill("KILL", @pid)
        end
    end

    def to_s
        "pid = #{@pid}\nstate = #{@state}\nfailures = #{@failures}\nexit_status = #{@exit_status}\n\n"
    end
    
    def config_to_s
        str = config.map do |key, val|
            "#{key} = #{val}"
        end.join("\n")

        sprintf("%s\n", str)
    end

    def should_restart?
        if @config["restart"] == "always"
            @failures < @config["max_failures"]
        elsif @config["restart"] == "on_success" && is_expected_exit?
            @failures < @config["max_failures"]
        elsif @config["restart"] == "unexpected" && !is_expected_exit?
            @failures < @config["max_failures"]
        else
            false
        end
    end
    
    def on_exit
        @log.info "Starting post-exit procedure"
        if @state != "terminated" && (@state != "exit" || @state != "exiting")
            @exit_status = $?.exitstatus
            @log.info "exit_status = #{exit_status}"

            @thread.exit

            if @state != "started"
                @state = "early_exit"
            end
            
            if !is_expected_exit?
                @log.info "Incrementing failure"
                @failures += 1
            end

            if should_restart?
                sleep @config["fail_cooldown"]
                @pid = nil
                start
            elsif !is_expected_exit?
                @pid = nil
                @state = "abandonned"
            else
                @pid = nil
                @state = "success"
            end

            @log.info "state = #{@state}"
        end
    end

end