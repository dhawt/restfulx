module RestfulX
  module ActiveModel
    # == Active Model FXML Serializer
    module Serializers
      module Fxml
        extend ::ActiveSupport::Concern
        include ::ActiveModel::Serialization
  
        class Serializer #:nodoc:
          class Attribute #:nodoc:
            attr_reader :name, :value, :type
  
            def initialize(name, serializable, raw_value=nil)
              @name, @serializable = name, serializable
              @value = raw_value || @serializable.send(name)
              @type = compute_type
            end
  
            def decorations
              decorations = {}
              decorations[:encoding] = 'base64' if type == :binary
              decorations[:type] = type unless type == :string
              decorations[:nil] = true if value.nil?
              decorations
            end
  
          protected
  
            def compute_type
              type = ActiveSupport::XmlMini::TYPE_NAMES[value.class.name]
              type ||= :string if value.respond_to?(:to_str)
              type ||= :yaml
              type
            end
          end
  
          class MethodAttribute < Attribute #:nodoc:
          end
  
          attr_reader :options
  
          def initialize(serializable, options = nil)
            @serializable = serializable
            @options = options ? options.dup : {}
  
            @options[:only] = Array.wrap(@options[:only]).map { |n| n.to_s }
            @options[:except] = Array.wrap(@options[:except]).map { |n| n.to_s }
          end
  
          # To replicate the behavior in ActiveRecord#attributes, <tt>:except</tt>
          # takes precedence over <tt>:only</tt>. If <tt>:only</tt> is not set
          # for a N level model but is set for the N+1 level models,
          # then because <tt>:except</tt> is set to a default value, the second
          # level model can have both <tt>:except</tt> and <tt>:only</tt> set. So if
          # <tt>:only</tt> is set, always delete <tt>:except</tt>.
          def attributes_hash
            attributes = @serializable.attributes
            if options[:only].any?
              attributes.slice(*options[:only])
            elsif options[:except].any?
              attributes.except(*options[:except])
            else
              attributes
            end
          end
  
          def serializable_attributes
            attributes_hash.map do |name, value|
              self.class::Attribute.new(name, @serializable, value)
            end
          end
  
          def serializable_methods
            Array.wrap(options[:methods]).map do |name|
              self.class::MethodAttribute.new(name.to_s, @serializable) if @serializable.respond_to?(name.to_s)
            end.compact
          end
  
          def serialize
            require 'builder' unless defined? ::Builder
  
            options[:indent] ||= 2
            options[:builder] ||= ::Builder::XmlMarkup.new(:indent => options[:indent])
  
            @builder = options[:builder]
            @builder.instruct! unless options[:skip_instruct]
  
            root = (options[:root] || @serializable.class.to_s.underscore).to_s
            root = ActiveSupport::XmlMini.rename_key(root, options)
  
            args = [root]
            args << {:xmlns => options[:namespace]} if options[:namespace]
            args << {:type => options[:type]} if options[:type] && !options[:skip_types]
  
            @builder.tag!(*args) do
              add_attributes_and_methods
              add_extra_behavior
              add_procs
              yield @builder if block_given?
            end
          end
  
        private
          def add_extra_behavior
          end
  
          def add_attributes_and_methods
            (serializable_attributes + serializable_methods).each do |attribute|
              key = ActiveSupport::XmlMini.rename_key(attribute.name, options)
              ActiveSupport::XmlMini.to_tag(key, attribute.value,
                options.merge(attribute.decorations))
            end
          end
  
          def add_procs
            if procs = options.delete(:procs)
              Array.wrap(procs).each do |proc|
                if proc.arity == 1
                  proc.call(options)
                else
                  proc.call(options, @serializable)
                end
              end
            end
          end
        end
  
        # Returns FXML representing the model. Configuration can be
        # passed through +options+.
        def to_fxml(options = {}, &block)
          options.merge!(:dasherize => false)
          default_except = [:encrypted_password, :password_salt, :remember_token, :remember_token_expires_at, :created_at, :updated_at]
          options[:except] = (options[:except] ? options[:except] + default_except : default_except)
          Serializer.new(self, options).serialize(&block)
        end
  
        def from_fxml(fxml)
          self.attributes = Hash.from_xml(fxml).values.first
          self
        end
      end
      
      module Amf
        class Serializer #:nodoc:
          extend ::ActiveSupport::Concern
          include ::ActiveModel::Serialization
          
          def initialize(record, options = {})
            super(record, options)
            @options[:methods] ||= []
            @options[:amf_version] = 3
            @options[:serializer] ||= RestfulX::AMF::RxAMFSerializer.new

            # options are duplicated by default so we need a copy for caching attributes
            @original_options = options
            @original_options[:cached_attributes] ||= {}
            @options[:cached_instances] = @original_options[:cached_instances] ||= {}
          end

          def serialize
            @options[:serializer].serialize_record(@record, serializable_attributes, @options) do |serializer|
              ([].concat(@options[:methods])).each do |method|
                if @record.respond_to?(method)
                  serializer.write_vr(method.to_s.camelcase(:lower))
                  serializer.serialize_property(@record.send(method))
                end
              end
              add_includes do |association, records, opts|
                add_associations(association, records, opts, serializer)
              end
            end.to_s
          end

          def serializable_attributes
            includes = @options[:include] ||= {}

            # if we are serializing an array we only need to compute serializable_attributes for the
            # objects of the same type at the same level once
            if @original_options[:cached_attributes].has_key?(@record.class.name)
              @original_options[:cached_attributes][@record.class.name]
            else
              associations = Hash[*@record.class.reflect_on_all_associations(:belongs_to).collect do |assoc|
                if assoc.options.has_key?(:polymorphic) && assoc.options[:polymorphic]
                  @options[:except] = ([] << @options[:except] << "#{assoc.name}_type".to_sym).flatten
                  # class_name = @record[assoc.options[:foreign_type]].constantize
                  class_name = "polymorphic"
                else
                  class_name = assoc.klass
                end
                [assoc.primary_key_name, {:name => assoc.name, :klass => class_name}]
              end.flatten]

              attributes = serializable_names.select do |name| 
                !includes.include?(associations[name][:name]) rescue true
              end.map do |name| 
                associations.has_key?(name) ? {:name => name, :ref_name => associations[name][:name].to_s.camelize(:lower), 
                  :ref_class => associations[name][:klass], :orig_ref_name => associations[name][:name].to_s } : name.to_sym
              end
              @original_options[:cached_attributes][@record.class.name] = attributes
              attributes
            end
          end

          def add_associations(association, records, opts, serializer)        
            serializer.write_vr(association.to_s.camelcase(:lower))
            if records.is_a?(Enumerable)
              serializer.serialize_models_array(records, opts)
            else
              if record = @record.send(association)
                record.to_amf(opts)
              end
            end
          end
        end
      end
    end

    module Errors
      alias_method :as_json_original, :as_json
      
      # serialize errors to JSON
      def as_json(options = {})
        "{#{'errors'.inspect}:#{as_json_original(options)}}"
      end

      # serialize errors to AMF
      def to_amf(options = {})
        options[:amf_version] = 3
        options[:serializer] ||= RestfulX::AMF::RxAMFSerializer.new
        options[:serializer].serialize_errors(Hash[*@errors.to_a.flatten]).to_s
      end
      
      def to_fxml(options = {})
        require 'active_support/builder' unless defined?(Builder)
        options[:root] ||= "errors"
        options[:indent] ||= 2
        options[:builder] ||= Builder::XmlMarkup.new(:indent => options[:indent])
        options[:builder].instruct! unless options.delete(:skip_instruct)
        options[:builder].errors do |e|
          each do |attr, msg|
            next if msg.nil?
            if attr == "base"
              options[:builder].error("message", msg.to_s)
            else
              options[:builder].error("field" => attr.to_s.camelize(:lower), "message" => msg.to_s)
            end
          end
        end
      end
    end
  end
end