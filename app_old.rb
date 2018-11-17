class Job
    attr_accessor(
        :pid,
        :stopped_at,
        :started_at,
        :name,
        :state,
        
        :cmd,
        :numprocs,
        :umask,
        :workingdir,
        :autostart,
        :autorestart,
        :exitcodes,
        :startretries,
        :starttime,
        :stopsignal,
        :stoptime,
        :stdout,
        :stderr,
        :env
    )

    def initialize(opts = {})
        @pid = nil
        @state = :not_running
        @startretries_count = 0
        @exitstatus = nil
        @process = nil
        
        @name = opts[:name]
        @cmd = opts[:cmd]
        @numprocs = opts[:numprocs]
        @umask = opts[:umask]
        @workingdir = opts[:workingdir]
        @autostart = opts[:autostart]
        @autorestart = opts[:autorestart].to_sym
        @exitcodes = opts[:exitcodes]
        @startretries = opts[:startretries]
        @starttime = opts[:starttime]
        @stopsignal = opts[:stopsignal]
        @stoptime = opts[:stoptime]
        @stdout = opts[:stdout]
        @stderr = opts[:stderr]
        @env = opts[:env]
    end

    def start
        if !is_running?
            @state = :starting
            @started_at = Time.now
            puts "starting"
            @pid = Process.fork do
                @env.map do |var, val|
                    ENV[var.to_s] = val.to_s
                end
                $stdout.reopen(@stdout, "w")
                $stderr.reopen(@stderr, "w")
                Dir.chdir(@workingdir)
                File.umask(@umask)
                #exec("bash", "-c", cmd)
                exit(1)
            end
            Thread.new do
                Process.wait(@pid)
                @process = $?
                @status = @process.exitstatus
            end
        end
    end

    def stop
        if is_running?
            @stopped_at = Time.now
            @state = :stopping
            Process.kill(@stopsignal, @pid)
            @pid = nil
        end
    end

    def kill!
        if is_running?
            Process.kill("SIGTERM")
            Process.detach(@pid)
            @state = :killed
            @pid = nil
        end
    end

    def is_running?
        if @pid
            Process.wait(@pid)
            !$?.exited?
        end
    rescue
        false
    end

    def is_stoptimeout?
        @state == :stopping && @stopped_at - Time.now > @stoptime
    end

    def is_starttimeout?
        @state == :starting && @started_at - Time.now > @starttime
    end

    def should_retry?
        if @startretries_count >= @startretries

            if @autorestart == :timeout && @state == :timeout
                true
            end
            
            if @autorestart == :always && job.succeeded?
                true
            end
            
            if @autorestart == :success && job.succeeded?
                true
            end
            
            if @autorestart == :unexpected && @state == :failed && @state == :killed
                true
            end

        end
    end

    def succeeded?
        if !@exitstatus.nil? && @exitcodes
            puts "exit code : #{@exitstatus}"
            @exitcodes.any? { |c| @exitstatus == c }
        end
    end

end

class Manager
    attr_accessor :jobs

    def autostart
        @jobs.each do |job|
            if job.autostart
                job.start
            end
        end
    end
    
    def routine
        @jobs.each do |job|

            if job.is_starttimeout?
                puts "starttimeout"
                job.state = :timeout
            end

            if job.should_retry?
                puts "should retry"
                job.startretries_count += 1
                job.start
            end

            if job.is_stoptimeout?
                puts "stop timeout"
                job.kill!
            end

            if !job.is_running?
                if job.succeeded?
                    puts "succeeded"
                    job.state = :success
                else
                    puts "failed"
                    job.state = :failed
                end
            end


        end
    end
end

manager = Manager.new

manager.jobs = [Job.new({
    name: "Echo",
    cmd: "echo sleeping... && sleep 2 && exit 3",
    umask: 077,
    numprocs: 2,
    workingdir: "/home/naki",
    autostart: true,
    autorestart: :always,
    exitcodes: [0, 2],
    startretries: 2,
    starttime: 5,
    stopsignal: "KILL",
    stoptime: 5,
    stdout: "/dev/stdout",
    stderr: "/dev/stderr",
    env: { VAR: "VAL" }
})]

manager.autostart
loop do
    manager.routine
    sleep 1
end