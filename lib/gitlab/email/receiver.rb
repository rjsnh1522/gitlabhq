# Inspired in great part by Discourse's Email::Receiver
module Gitlab
  module Email
    class Receiver
      class ProcessingError < StandardError; end
      class EmailUnparsableError < ProcessingError; end
      class SentNotificationNotFoundError < ProcessingError; end
      class EmptyEmailError < ProcessingError; end
      class AutoGeneratedEmailError < ProcessingError; end
      class UserNotFoundError < ProcessingError; end
      class UserBlockedError < ProcessingError; end
      class UserNotAuthorizedError < ProcessingError; end
      class NoteableNotFoundError < ProcessingError; end
      class InvalidNoteError < ProcessingError; end
      class InvalidIssueError < ProcessingError; end

      def initialize(raw)
        @raw = raw
      end

      def execute
        raise EmptyEmailError if @raw.blank?

        if sent_notification
          process_reply

        elsif message_project
          process_create_issue

        else
          # TODO: could also be project not found
          raise SentNotificationNotFoundError
        end
      end

      private
      def process_reply
        raise AutoGeneratedEmailError if message.header.to_s =~ /auto-(generated|replied)/

        author = sent_notification.recipient
        project = sent_notification.project

        check_input(author, project, :create_note)

        raise NoteableNotFoundError unless sent_notification.noteable

        note = create_note(extract_reply(project))

        unless note.persisted?
          msg = "The comment could not be created for the following reasons:"
          note.errors.full_messages.each do |error|
            msg << "\n\n- #{error}"
          end

          raise InvalidNoteError, msg
        end
      end

      def process_create_issue
        check_input(message_sender, message_project, :create_issue)

        issue = Issues::CreateService.new(message_project, message_sender,
          title: message.subject,
          description: extract_reply(message_project)).execute

        unless issue.persisted?
          msg = "The issue could not be created for the following reasons:"
          issue.errors.full_messages.each do |error|
            msg << "\n\n- #{error}"
          end

          raise InvalidIssueError, msg
        end
      end

      def check_input(author, project, permission)
        if author
          if author.blocked?
            raise UserBlockedError
          elsif project.nil? || !author.can?(permission, project)
            # TODO: Give project not found error if author cannot read project
            raise UserNotAuthorizedError
          end
        else
          raise UserNotFoundError
        end
      end

      # Find the first matched user in database from email From: section
      # TODO: Since this address could be forged, we should have some kind of
      #       auth token attached somewhere to verify the identity better.
      def message_sender
        @message_sender ||= message.from.find do |email|
          user = User.find_by_any_email(email)
          break user if user
        end
      end

      def message_project
        @message_project ||=
          Project.find_with_namespace(reply_key) if reply_key
      end

      def extract_reply project
        reply = ReplyParser.new(message).execute.strip

        raise EmptyEmailError if reply.blank?

        add_attachments(reply, project)

        reply
      end

      def message
        @message ||= Mail::Message.new(@raw)
      rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError => e
        raise EmailUnparsableError, e
      end

      def reply_key
        key_from_to_header || key_from_additional_headers
      end

      def key_from_to_header
        key = nil
        message.to.each do |address|
          key = Gitlab::IncomingEmail.key_from_address(address)
          break if key
        end

        key
      end

      def key_from_additional_headers
        reply_key = nil

        Array(message.references).each do |message_id|
          reply_key = Gitlab::IncomingEmail.key_from_fallback_reply_message_id(message_id)
          break if reply_key
        end

        reply_key
      end

      def sent_notification
        return nil unless reply_key

        SentNotification.for(reply_key)
      end

      def add_attachments(reply, project)
        attachments = Email::AttachmentUploader.new(message).execute(project)

        attachments.each do |link|
          reply << "\n\n#{link[:markdown]}"
        end

        reply
      end

      def create_note(reply)
        Notes::CreateService.new(
          sent_notification.project,
          sent_notification.recipient,
          note:           reply,
          noteable_type:  sent_notification.noteable_type,
          noteable_id:    sent_notification.noteable_id,
          commit_id:      sent_notification.commit_id,
          line_code:      sent_notification.line_code
        ).execute
      end
    end
  end
end
