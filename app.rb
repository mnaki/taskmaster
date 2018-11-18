#!/usr/bin/ruby

require './job_manager.class.rb'
require './job.class.rb'

debug_config = [
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

# jm = JobManager.new(debug_config)
jm = JobManager.new([])
jm.reload

loop do
    jm.read_line
end