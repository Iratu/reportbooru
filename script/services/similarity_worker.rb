#!/home/danbooru/.rbenv/shims/ruby

require "redis"
require "logger"
require "aws-sdk"
require 'optparse'
require File.expand_path("../../../config/environment", __FILE__)

# your environment should set AWS_REGION, AWS_ACCESS_KEY, and 
# AWS_SECRET_ACCESS_KEY

Process.daemon
# Process.setpriority(Process::PRIO_USER, 0, 10)

$running = true
$options = {
  pidfile: "/var/run/reportbooru/similarity_worker.pid",
  logfile: "/var/log/reportbooru/similarity_worker.log"
}

OptionParser.new do |opts|
  opts.on("--pidfile=PIDFILE") do |pidfile|
    $options[:pidfile] = pidfile
  end

  opts.on("--logfile=LOGFILE") do |logfile|
    $options[:logfile] = logfile
  end
end.parse!

logfile = File.open($options[:logfile], "a")
logfile.sync = true
LOGGER = Logger.new(logfile)
REDIS = Redis.new
SQS_QUEUE_URL = ENV["aws_sqs_similarity_queue_url"]
SQS_CLIENT = Aws::SQS::Client.new
SQS_POLLER = Aws::SQS::QueuePoller.new(SQS_QUEUE_URL, client: SQS_CLIENT)

File.open($options[:pidfile], "w") do |f|
  f.write(Process.pid)
end

Signal.trap("TERM") do
  $running = false
end

SQS_POLLER.before_request do
  unless $running
    throw :stop_polling
  end
end

while $running
  begin
    SQS_POLLER.poll do |msg|
      if msg.body =~ /simusers-(\d+)/
        user_id = $1
        LOGGER.info "processing #{user_id}"
        query = UserSimilarityQuery.new(user_id)
        query.calculate
      elsif msg.body =~ /simpvotes-(\d+)/
        user_id = $1
        LOGGER.info "processing #{user_id}"
        query = PostVoteSimilarityQuery.new(user_id)
        query.calculate
      elsif msg.body =~ /targetedpostdownvoting-(\d+)-(\d+)/
        # hijacking this service to send async reports
        user_id = $1
        post_id = $2
        LOGGER.info "processing targeted post down voting report for #{user_id}"
        MessagedReports::TargetedPostDownVoting.new(user_id, post_id).send_message
      else
        LOGGER.error "unknown message: #{msg.body}"
      end
    end
  rescue PG::ConnectionBad, PG::UnableToSend => e
    LOGGER.error "error: #{e}"
    sleep(30)
    DanbooruRo::Base.connection.reconnect!
  rescue Exception => e
    LOGGER.error e.message
    LOGGER.error e.backtrace.join("\n")
    60.times do
      sleep(1)
      exit unless $running
    end
    retry
  end
end
