
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
        @config = config

        @thread = nil
        @process = nil

        @failures = 0
        @pid = nil
        @exit_status = nil
        @state = nil

        if config["autostart"] == true
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
        @thread = Thread.new do
            begin
                @state = "starting"
                sleep @config["start_minimum_time"]
                if is_running?
                    @state = "started"
                end
            rescue Exception => e
                puts "EXCEPTION: #{e.inspect}"
                puts "ZZZ MESSAGE: #{e.message}"
                Process.exit
            end
        end
        @pid = Process.fork do
            @exit_status = nil
            if @config["env"]
                @config["env"].map do |var, val|
                    ENV[var.to_s] = val.to_s
                end
            end
            $stdout.reopen(@config["stdout"], "w") if @config["stdout"]
            $stderr.reopen(@config["stderr"], "w") if @config["stderr"]
            Dir.chdir(@config["working_dir"])
            File.umask(@config["umask"].to_i(8))
            exec("bash", "-c", @config["cmd"])
            exit(1)
        end
        Process.wait(@pid)
        on_exit
    end

    def restart
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
        if @state != "terminated" && (@state != "exit" || @state != "exiting")
            @exit_status = $?.exitstatus
            @thread.exit
            if @state != "started"
                @state = "early_exit"
            end
            
            if !is_expected_exit?
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
        end
    end

end