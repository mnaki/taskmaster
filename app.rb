#!/usr/bin/ruby

require 'scanf'
require 'yaml'

config = [
    {
        "name" => "hello",
        "fail_cooldown" => 2,
        "processes" => 1,
        "autostart" => true,
        "exit_signal" => "TERM",
        "max_failures" => 2,
        "exit_timeout" => 3,
        "cmd" => "pwd && date +%s && env | grep LOL && sleep 2 && exit 2",
        "expected_status" => [0, 2],
        "restart" => "unexpected",
        "stdout" => "out",
        "start_minimum_time" => 0.5,
        "working_dir" => "/dev",
        "umask" => "077",
        "env" => {
            "LOL" => "OK"
        }
    }
]

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



class JobManager
    # attr_accessor()
    
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

jm = JobManager.new(config)

loop do
    jm.read_line
end