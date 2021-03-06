module ElasticRansack
  class Search
    include ::ElasticRansack::Naming
    include Enumerable

    attr_reader :options, :search_options, :model, :search_results, :sorts, :globalize

    delegate :results, :each, :each_with_index, :each_with_hit, :empty?, :size, :[], to: :search_results
    delegate :total_entries, :per_page, :total_pages, :current_page, :previous_page, :next_page, :offset, :out_of_bounds?,
             to: :search_results

    alias_method :klass, :model

    DATETIME_REGEXP = /\d{2}\.\d{2}.\d{4} \d{2}\:\d{2}/
    DATE_REGEXP = /\d{2}\.\d{2}.\d{4}/

    def initialize(model, options, search_options)
      search_options ||= {}
      search_options.reverse_merge!(globalize: true)
      @model = model
      @options = options.stringify_keys
      @search_options = search_options || {}
      @search_options[:escape_query] = true unless @search_options.has_key?(:escape_query)
      @sorts = []
      @globalize = @search_options.delete(:globalize)
      sorting = @options.delete('s')
      if sorting.blank?
        add_sort('_score', 'desc')
        add_sort('id', 'desc')
      else
        sorting_split = sorting.split(/\s+/)
        sorting_split.each_slice(2) do |sort|
          add_sort(sort[0], sort[1] || 'asc')
        end
      end
    end

    def add_sort(name, dir)
      @sorts << OpenStruct.new(name: name, dir: dir)
    end

    def search
      @search_results ||= begin
        that = self
        query_string = []
        escape_query = @search_options[:escape_query]
        tire.search(@search_options) do
          and_filters = []
          sort do
            that.sorts.each do |s|
              by s.name, s.dir
            end
          end

          that.options.each do |k, v|
            next if v.blank?
            v = ElasticRansack.normalize_integer_vals(k, v)

            if k == 'q_cont' || k == 'q_eq'
              v = v.lucene_escape if escape_query
              query_string << "#{v}" if v.present?
              next
            end

            if k =~ /^(.+)_cont$/
              attr = $1
              attr = "#{$1.sub(/^translations_/, '')}_#{I18n.locale}" if that.globalize && attr =~ /^translations_(.+)/
              attr_query = [
                  v.split.map { |part| "#{attr}:*#{part.lucene_escape}*" }.join(' AND '),
                  v.split.map { |part| "#{attr}:\"#{part.lucene_escape}\"" }.join(' AND ')
              ]
              query_string << attr_query.map { |q| "(#{q})" }.join(' OR ')
              next
            else
              v = that.format_value(v)
            end

            ElasticRansack.predicates.each do |predicate|
              if k =~ predicate.regexp
                and_filters << predicate.query.call($1, v)
                break
              end
            end
          end

          query { string query_string.join(' ') } unless query_string.blank?
          filter(:and, filters: and_filters) unless and_filters.blank?
        end
      end
    end


    def translate(*args)
      model.human_attribute_name(args.first)
    end

    def format_value(v)
      if v =~ DATETIME_REGEXP
        ElasticRansack.datetime_parser.call(v)
      elsif v =~ DATE_REGEXP
        ElasticRansack.datetime_parser.call(v).to_date
      else
        v
      end
    end

    def method_missing(*args, &block)
      @model.send(*args, &block)
    end
  end
end
