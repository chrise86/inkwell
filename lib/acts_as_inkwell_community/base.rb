module Inkwell
  module ActsAsInkwellCommunity
    module Base
      def self.included(klass)
        klass.class_eval do
          extend Config
        end
      end
    end

    module Config
      def acts_as_inkwell_community
        validates :owner_id, :presence => true

        after_create :processing_a_community
        before_destroy :destroy_community_processing

        include ::Inkwell::ActsAsInkwellCommunity::InstanceMethods
        include ::Inkwell::Common
      end
    end

    module InstanceMethods

      def add_user(options = {})
        options.symbolize_keys!
        user = options[:user]
        return if self.include_user? user

        users_ids = ActiveSupport::JSON.decode self.users_ids
        users_ids << user.id
        self.users_ids = ActiveSupport::JSON.encode users_ids
        self.save

        communities_ids = ActiveSupport::JSON.decode user.communities_ids
        communities_ids << self.id
        user.communities_ids = ActiveSupport::JSON.encode communities_ids
        user.save

        post_class = Object.const_get ::Inkwell::Engine::config.post_table.to_s.singularize.capitalize
        user_id_attr = "#{::Inkwell::Engine::config.user_table.to_s.singularize}_id"
        ::Inkwell::BlogItem.where(:owner_id => self.id, :is_owner_user => false).order("created_at DESC").limit(10).each do |blog_item|
          next if post_class.find(blog_item.item_id).send(user_id_attr) == user.id

          item = ::Inkwell::TimelineItem.send "find_by_item_id_and_#{user_id_attr}_and_is_comment", blog_item.item_id, user.id, blog_item.is_comment
          if item
            item.has_many_sources = true unless item.has_many_sources
            sources = ActiveSupport::JSON.decode item.from_source
            sources << Hash['community_id' => self.id]
            item.from_source = ActiveSupport::JSON.encode sources
            item.save
          else
            sources = [Hash['community_id' => self.id]]
            ::Inkwell::TimelineItem.create :item_id => blog_item.item_id, :is_comment => blog_item.is_comment, :user_id => user.id,
                                           :from_source => ActiveSupport::JSON.encode(sources), :created_at => blog_item.created_at
          end
        end
      end

      def remove_user(options = {})
        options.symbolize_keys!
        user = options[:user]
        admin = options[:admin]
        return unless self.include_user? user
        raise "admin is not admin" if admin && !self.include_admin?(admin)
        if self.include_admin? user
          raise "community owner can not be removed from his community" if self.admin_level_of(user) == 0
          raise "admin has no permissions to delete this user from community" if (self.admin_level_of(user) <= self.admin_level_of(admin)) && (user != admin)
        end

        users_ids = ActiveSupport::JSON.decode self.users_ids
        users_ids.delete user.id
        self.users_ids = ActiveSupport::JSON.encode users_ids
        self.save

        communities_ids = ActiveSupport::JSON.decode user.communities_ids
        communities_ids.delete self.id
        user.communities_ids = ActiveSupport::JSON.encode communities_ids
        user.save

        user_id_attr = "#{::Inkwell::Engine::config.user_table.to_s.singularize}_id"

        timeline_items = ::Inkwell::TimelineItem.where "from_source like '%{\"community_id\":#{self.id}%' and #{user_id_attr} = #{user.id}"
        timeline_items.delete_all :has_many_sources => false
        timeline_items.each do |item|
          from_source = ActiveSupport::JSON.decode item.from_source
          from_source.delete_if { |rec| rec['community_id'] == self.id }
          item.from_source = ActiveSupport::JSON.encode from_source
          item.has_many_sources = false if from_source.size < 2
          item.save
        end
      end

      def include_user?(user)
        check_user user
        communities_ids = ActiveSupport::JSON.decode user.communities_ids
        communities_ids.include? self.id
      end

      def add_admin(options = {})
        options.symbolize_keys!
        user = options[:user]
        admin = options[:admin]
        raise "admin should be passed in params" unless admin
        raise "user is already admin" if self.include_admin?(user)
        raise "admin is not admin" unless self.include_admin?(admin)
        raise "user should be a member of this community" unless self.include_user?(user)

        admin_level_granted_for_user = admin_level_of(admin) + 1

        admin_positions = ActiveSupport::JSON.decode user.admin_of
        admin_positions << Hash['community_id' => self.id, 'admin_level' => admin_level_granted_for_user]
        user.admin_of = ActiveSupport::JSON.encode admin_positions
        user.save

        admins_info = ActiveSupport::JSON.decode self.admins_info
        admins_info << Hash['admin_id' => user.id, 'admin_level' => admin_level_granted_for_user]
        self.admins_info = ActiveSupport::JSON.encode admins_info
        self.save
      end

      def remove_admin(options = {})
        options.symbolize_keys!
        user = options[:user]
        admin = options[:admin]
        raise "user should be passed in params" unless user
        raise "admin should be passed in params" unless admin
        raise "user is not admin" unless self.include_admin?(user)
        raise "admin is not admin" unless self.include_admin?(admin)
        raise "admin has no permissions to delete this user from admins" if (admin_level_of(admin) >= admin_level_of(user)) && (user != admin)
        raise "community owner can not be removed from admins" if admin_level_of(user) == 0

        admin_positions = ActiveSupport::JSON.decode user.admin_of
        admin_positions.delete_if{|rec| rec['community_id'] == self.id}
        user.admin_of = ActiveSupport::JSON.encode admin_positions
        user.save

        admins_info = ActiveSupport::JSON.decode self.admins_info
        admins_info.delete_if{|rec| rec['admin_id'] == user.id}
        self.admins_info = ActiveSupport::JSON.encode admins_info
        self.save
      end

      def admin_level_of(admin)
        admin_positions = ActiveSupport::JSON.decode admin.admin_of
        index = admin_positions.index{|item| item['community_id'] == self.id}
        raise "admin is not admin" unless index
        admin_positions[index]['admin_level']
      end

      def include_admin?(user)
        check_user user
        admin_positions = ActiveSupport::JSON.decode user.admin_of
        (admin_positions.index{|item| item['community_id'] == self.id} == nil) ? false : true
      end

      def add_post(options = {})
        options.symbolize_keys!
        user = options[:user]
        post = options[:post]
        raise "user should be passed in params" unless user
        raise "user should be a member of community" unless self.include_user?(user)
        raise "post should be passed in params" unless post
        check_post post
        user_id_attr = "#{::Inkwell::Engine::config.user_table.to_s.singularize}_id"
        raise "user tried to add post of another user" unless post.send(user_id_attr) == user.id
        raise "post is already added to this community" if post.communities_row.include? self.id

        ::Inkwell::BlogItem.create :owner_id => self.id, :is_owner_user => false, :item_id => post.id, :is_comment => false
        communities_ids = ActiveSupport::JSON.decode post.communities_ids
        communities_ids << self.id
        post.communities_ids = ActiveSupport::JSON.encode communities_ids
        post.save

        users_with_existing_items = [user.id]
        ::Inkwell::TimelineItem.where(:item_id => post.id, :is_comment => false).each do |item|
          users_with_existing_items << item.send(user_id_attr)
          item.has_many_sources = true
          from_source = ActiveSupport::JSON.decode item.from_source
          from_source << Hash['community_id' => self.id]
          item.from_source = ActiveSupport::JSON.encode from_source
          item.save
        end

        self.users_row.each do |user_id|
          next if users_with_existing_items.include? user_id
          ::Inkwell::TimelineItem.create :item_id => post.id, user_id_attr => user_id, :is_comment => false,
                                         :from_source => ActiveSupport::JSON.encode([Hash['community_id' => self.id]])
        end
      end

      def remove_post(options = {})
        options.symbolize_keys!
        user = options[:user]
        post = options[:post]
        raise "user should be passed in params" unless user
        raise "user should be a member of community" unless self.include_user?(user)
        raise "post should be passed in params" unless post
        check_post post
        user_class = Object.const_get ::Inkwell::Engine::config.user_table.to_s.singularize.capitalize
        user_id_attr = "#{::Inkwell::Engine::config.user_table.to_s.singularize}_id"
        if self.include_admin?(user)
          post_owner = user_class.find post.send(user_id_attr)
          raise "admin tries to remove post of another admin. not enough permissions" if
              (self.include_admin? post_owner) && (self.admin_level_of(user) > self.admin_level_of(post_owner))
        else
          raise "user tried to remove post of another user" unless post.send(user_id_attr) == user.id
        end
        raise "post isn't in community" unless post.communities_row.include? self.id

        ::Inkwell::BlogItem.delete_all :owner_id => self.id, :is_owner_user => false, :item_id => post.id, :is_comment => false
        communities_ids = ActiveSupport::JSON.decode post.communities_ids
        communities_ids.delete self.id
        post.communities_ids = ActiveSupport::JSON.encode communities_ids
        post.save

        items = ::Inkwell::TimelineItem.where(:item_id => post.id, :is_comment => false).where("from_source like '%{\"community_id\":#{self.id}%'")
        items.where(:has_many_sources => false).delete_all
        items.where(:has_many_sources => true).each do |item|
          from_source = ActiveSupport::JSON.decode item.from_source
          from_source.delete Hash['community_id' => self.id]
          item.from_source = ActiveSupport::JSON.encode from_source
          item.has_many_sources = false if from_source.size < 2
          item.save
        end
      end

      def blogline(options = {})
        options.symbolize_keys!
        last_shown_obj_id = options[:last_shown_obj_id]
        limit = options[:limit] || 10
        for_user = options[:for_user]

        if last_shown_obj_id
          blog_items = ::Inkwell::BlogItem.where(:owner_id => self.id, :is_owner_user => false).where("created_at < ?", Inkwell::BlogItem.find(last_shown_obj_id).created_at).order("created_at DESC").limit(limit)
        else
          blog_items = ::Inkwell::BlogItem.where(:owner_id => self.id, :is_owner_user => false).order("created_at DESC").limit(limit)
        end

        post_class = Object.const_get ::Inkwell::Engine::config.post_table.to_s.singularize.capitalize
        result = []
        blog_items.each do |item|
          if item.is_comment
            blog_obj = ::Inkwell::Comment.find item.item_id
          else
            blog_obj = post_class.find item.item_id
          end

          blog_obj.item_id_in_line = item.id
          blog_obj.is_reblog_in_blogline = item.is_reblog

          if for_user
            blog_obj.is_reblogged = for_user.reblog? blog_obj
            blog_obj.is_favorited = for_user.favorite? blog_obj
          end

          result << blog_obj
        end
        result
      end

      def users_row
        ActiveSupport::JSON.decode self.users_ids
      end

      private
      def processing_a_community
        user_class = Object.const_get ::Inkwell::Engine::config.user_table.to_s.singularize.capitalize
        user = user_class.find self.owner_id

        admin_positions = ActiveSupport::JSON.decode user.admin_of
        admin_positions << Hash['community_id' => self.id, 'admin_level' => 0]
        user.admin_of = ActiveSupport::JSON.encode admin_positions
        communities_ids = ActiveSupport::JSON.decode user.communities_ids
        communities_ids << self.id
        user.communities_ids = ActiveSupport::JSON.encode communities_ids
        user.save

        admins_info = [Hash['admin_id' => user.id, 'admin_level' => 0]]
        self.admins_info = ActiveSupport::JSON.encode admins_info
        self.users_ids = ActiveSupport::JSON.encode [user.id]
        self.save
      end

      def destroy_community_processing
        user_class = Object.const_get ::Inkwell::Engine::config.user_table.to_s.singularize.capitalize
        users_ids = ActiveSupport::JSON.decode self.users_ids
        users_ids.each do |user_id|
          user = user_class.find user_id
          admin_positions = ActiveSupport::JSON.decode user.admin_of
          admin_positions.delete_if{|rec| rec['community_id'] == self.id}
          user.admin_of = ActiveSupport::JSON.encode admin_positions
          communities_ids = ActiveSupport::JSON.decode user.communities_ids
          communities_ids.delete self.id
          user.communities_ids = ActiveSupport::JSON.encode communities_ids
          user.save
        end

        timeline_items = ::Inkwell::TimelineItem.where "from_source like '%{\"community_id\":#{self.id}%'"
        timeline_items.delete_all :has_many_sources => false
        timeline_items.each do |item|
          from_source = ActiveSupport::JSON.decode item.from_source
          from_source.delete_if { |rec| rec['community_id'] == self.id }
          item.from_source = ActiveSupport::JSON.encode from_source
          item.has_many_sources = false if from_source.size < 2
          item.save
        end

        ::Inkwell::BlogItem.delete_all :owner_id => self.id, :is_owner_user => false

      end
    end
  end
end

::ActiveRecord::Base.send :include, ::Inkwell::ActsAsInkwellCommunity::Base