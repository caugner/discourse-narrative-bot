module DiscourseNarrativeBot
  class TrackSelector
    include Actions

    GENERIC_REPLIES_COUNT_PREFIX = 'discourse-narrative-bot:track-selector-count:'.freeze

    TRACKS = [
      NewUserNarrative,
      AdvancedUserNarrative
    ]

    RESET_TRIGGER = 'start'.freeze
    SKIP_TRIGGER = 'skip'.freeze

    TOPIC_ACTIONS = [
      :delete,
      :topic_notification_level_changed
    ].each(&:freeze)

    def initialize(input, user, post_id:, topic_id: nil)
      @input = input
      @user = user
      @post_id = post_id
      @topic_id = topic_id
      @post = Post.find_by(id: post_id)
    end

    def select
      data = Store.get(@user.id)

      if @post && !is_topic_action?
        topic_id = @post.topic_id
        post_analyzer = PostAnalyzer.new(@post.raw, topic_id)

        TRACKS.each do |klass|
          if selected_track(klass)
            klass.new.reset_bot(@user, @post)
            return
          end
        end

        bot_mentioned = post_analyzer.raw_mentions.include?(
          self.class.discobot_user.username
        )
        is_reply = @input == :reply

        if (data && data[:topic_id] == topic_id)
          state = data[:state]
          klass = (data[:track] || NewUserNarrative.to_s).constantize

          if is_reply && like_user_post
            data[:state] = nil
            Store.set(@user.id, data)
            return
          end

          if state&.to_sym == :end && is_reply
            bot_commands(bot_mentioned) || generic_replies(klass::RESET_TRIGGER)
          elsif is_reply
            previous_status = data[:attempted]
            current_status = klass.new.input(@input, @user, post: @post, skip: skip_track?)
            data = Store.get(@user.id)
            data[:attempted] = !current_status

            if previous_status && data[:attempted] == previous_status
              generic_replies(klass::RESET_TRIGGER, state)
            else
              $redis.del(generic_replies_key(@user))
            end

            Store.set(@user.id, data)
          else
            klass.new.input(@input, @user, post: @post, skip: skip_track?)
          end
        elsif is_reply && (bot_mentioned || pm_to_bot?(@post) || reply_to_bot_post?(@post))
          like_user_post
          bot_commands
        end
      elsif data && data.dig(:state)&.to_sym != :end && is_topic_action?
        klass = (data[:track] || NewUserNarrative.to_s).constantize
        klass.new.input(@input, @user, post: @post, topic_id: @topic_id)
      end
    end

    private

    def is_topic_action?
      @is_topic_action ||= TOPIC_ACTIONS.include?(@input)
    end

    def selected_track(klass)
      return if klass.respond_to?(:can_start?) && !klass.can_start?(@user)
      match_trigger?(@post.raw, "#{RESET_TRIGGER} #{klass::RESET_TRIGGER}")
    end

    def bot_commands(display_help = true)
      post_raw = @post.raw
      discobot_username = self.class.discobot_user.username

      raw =
        if match_data = match_trigger?(post_raw, 'roll (\d+)d(\d+)')
          I18n.t(i18n_key('random_mention.dice'),
            results: Dice.new(match_data[1].to_i, match_data[2].to_i).roll.join(", ")
          )
        elsif match_data = match_trigger?(post_raw, 'quote')
          I18n.t(i18n_key('random_mention.quote'), QuoteGenerator.generate)
        elsif display_help
          data = Store.get(@user.id)

          tracks = [NewUserNarrative::RESET_TRIGGER]

          if (data && (completed = data[:completed]) && completed.include?(NewUserNarrative.to_s)) ||
              @user.staff?

            tracks << AdvancedUserNarrative::RESET_TRIGGER
          end

          message = I18n.t(
            i18n_key('random_mention.tracks'),
            discobot_username: discobot_username,
            reset_trigger: RESET_TRIGGER,
            default_track: NewUserNarrative::RESET_TRIGGER,
            tracks: tracks.join(', ')
          )

          message << "\n\n#{I18n.t(i18n_key('random_mention.bot_actions'), discobot_username: discobot_username)}"
        end

      if raw
        fake_delay
        reply_to(@post, raw)
      end
    end

    def generic_replies_key(user)
      "#{GENERIC_REPLIES_COUNT_PREFIX}#{user.id}"
    end

    def generic_replies(reset_trigger, state = nil)
      reset_trigger = "#{RESET_TRIGGER} #{reset_trigger}"
      key = generic_replies_key(@user)
      count = ($redis.get(key) || $redis.setex(key, 900, 0)).to_i

      case count
      when 0
        raw = I18n.t(i18n_key('do_not_understand.first_response'))

        if state && state.to_sym != :end
          raw = "#{raw}\n\n#{I18n.t(i18n_key('do_not_understand.track_response'), reset_trigger: reset_trigger, skip_trigger: SKIP_TRIGGER)}"
        end

        reply_to(@post, raw)
      when 1
        reply_to(@post, I18n.t(i18n_key('do_not_understand.second_response'),
          reset_trigger: reset_trigger
        ))
      else
        # Stay out of the user's way
      end

      $redis.incr(key)
    end

    def i18n_key(key)
      "discourse_narrative_bot.track_selector.#{key}"
    end

    def skip_track?
      if pm_to_bot?(@post)
        post_raw = @post.raw

        post_raw.match(/^@#{self.class.discobot_user.username} #{SKIP_TRIGGER}/i) ||
          post_raw.strip == SKIP_TRIGGER
      else
        false
      end
    end

    def match_trigger?(text, trigger)
      match = text.match(Regexp.new("^@#{self.class.discobot_user.username} #{trigger}", 'i'))

      if pm_to_bot?(@post)
        match || text.strip.match(Regexp.new("^#{trigger}$", 'i'))
      else
        match
      end
    end

    def like_user_post
      if @post.raw.match(/thank/i)
        PostAction.act(self.class.discobot_user, @post, PostActionType.types[:like])
      end
    end
  end
end
