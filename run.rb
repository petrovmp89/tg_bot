# encoding: utf-8

require 'telegram/bot'
require 'rubygems'
require 'active_resource'
require 'rest-client'
require 'json'
require 'yaml'

class Issue < ActiveResource::Base
  settings = YAML.load_file('settings.yml')
  self.site = 'http://' + settings['domain']
  self.user = settings['username']
  self.password = settings['password']
end

settings = YAML.load_file('settings.yml')
logger = Logger.new(settings['log_file'])
logger.info "####{Time.now}###"
retried = 0
Telegram::Bot::Client.run(settings['token']) do |bot|
  begin
    project_id = settings['project_id']
    bot.listen do |message|
      logger.warn "####{Time.now}###"
      logger.warn message.from.id
      if settings['access_list'].include? message.from.id
        case message.text
        when /(мля|косяк|нужно)\s(\S|\s)+/
          telegram_user_id = message.from.id
          priority_key = message.text.split(' ')[0]
          issue_name = message.text.split("#{priority_key} ")[1]
          issue_description = ''
          issue_priority = settings['priority']["#{priority_key}"]
          bot.api.sendMessage(chat_id: message.chat.id,
                              text: "Ready to prepare task: #{issue_name}")
          bot.listen do |task_message|
            break if task_message.text == 'все'
            dirty_file_id = task_message.inspect.to_s.scan(/file_id=["]\S+["]/).last
            if dirty_file_id
              file_id = dirty_file_id.split('=')[1][1..-2]
              dirty_file_path = bot.api.getFile(file_id: file_id)
              file_path = dirty_file_path['result']['file_path']
              url = "https://api.telegram.org/file/bot#{settings['token']}/#{file_path}"
              img = RestClient.get(url)
              File.write("#{file_path.split('/')[1]}", img)
            else
              phrase = [task_message.text, "\n"].join(' ')
              issue_description << phrase
            end
          end
          issue = Issue.new(
            subject: issue_name,
            project_id: project_id,
            assigned_to_id: settings['assigned_to_id'],
            priority_id: issue_priority,
            description: issue_description
          )
          attachments = []
          Dir['file*'].each do |file|
            upload_url = "http://#{settings['domain']}/uploads.json?key=#{settings['api_key']}"
            img = File.new(file)
            response = RestClient.post(
              upload_url,
              img,
              multipart: true,
              content_type: 'application/octet-stream')
            token = JSON.parse(response)['upload']['token']
            attachments << { "token": token, "filename": file }
          end
          issue.uploads = attachments
          if issue.save
            Dir['file*'].each { |file| File.delete(file) }
            logger.info "####{Time.now}###"
            logger.info issue.id
            logger.info issue.subject
            logger.info telegram_user_id
            logger.info issue.author.name
          else
            logger.info "####{Time.now}###"
            logger.info issue.errors.full_messages
          end
          bot.api.sendMessage(chat_id: message.chat.id,
                              text: "Issue #{issue.id} was created!")
          link = 'https://' + settings['domain'] + '/issues/' + issue.id.to_s
          bot.api.sendMessage(chat_id: message.chat.id,
                              text: "#{link}")
        else
          bot.api.sendMessage(chat_id: message.chat.id,
                              text: "#{File.read('README.md')}")
        end
      else
        bot.api.sendMessage(chat_id: message.chat.id,
                            text: 'Permission deny')
      end
    end
  rescue
    if (retried += 1) < settings['attempts']
      sleep 10
      logger.warn "####{Time.now}###"
      logger.warn $!.message
      retry
    else
      logger.error "####{Time.now}###"
      logger.error $!.message
      logger.error 'Limit attempts exhausted'
    end
  end
end
