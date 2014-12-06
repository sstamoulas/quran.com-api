# vim: ts=4 sw=4 expandtab
class Content::Translation < ActiveRecord::Base
    extend Content
    extend Batchelor

    self.table_name = 'translation'
    self.primary_keys = :ayah_key, :resource_id # composite primary key which is a combination of ayah_key & resource_id

    # relationships
    belongs_to :resource, class_name: 'Content::Resource'
    belongs_to :ayah,     class_name: 'Quran::Ayah'

    # scope
    # default_scope { where resource_id: 17 } # NOTE uncomment or modify to disable/experiment on the elasticsearch import
    scope :ordered,     ->              { joins( 'join quran.ayah on translation.ayah_key = ayah.ayah_key' ).order( 'translation.resource_id asc, ayah.surah_id asc, ayah.ayah_num asc' ) }
    scope :resource_id, ->(id_resource) { ordered.where( resource_id: id_resource ) }
    scope :resource_17, -> { where resource_id: 17 }

    def self.import( options = {} )
        # we want to loop through each language code (in general)
        Content::Resource.select( :language_code ).distinct.map { |row| row.language_code }.each do |lc|
            # except when we specify a specific index, e.g. translation-en, so we'll just break out if we have lc already set
            if options.key?( :index ) and options[:index].split( '-' ).length > 1
                lc = options[:index].split( /-/ )[ -1 ]
                no_loop = true
            end

            # transforms the index name from "translation" into "translation-en":
            Content::Translation.connection.cache do
                index_name_lc = "#{index_name}-#{lc}"

                # we add a query proc to limit each import iteration by language code
                query = lambda do
                    Rails.logger.debug( "got query" )
                    joins( 'join content.resource using ( resource_id )' ).select( 'content.translation.*' ).where( 'resource.language_code' => lc )
                end

                transform = lambda do |a|
                    { index: {
                            _id: "#{a.resource_id}:#{a.ayah_key}",
                        _parent: a.ayah_key,
                           data: a.__elasticsearch__.as_indexed_json.merge( { 'resource' => a.resource.__elasticsearch__.as_indexed_json, 'language' => a.resource.language.__elasticsearch__.as_indexed_json, 'source' => a.resource.source.__elasticsearch__.as_indexed_json, 'author' => a.resource.author.__elasticsearch__.as_indexed_json } )
                    } }
                end

                options = { index: index_name_lc, query: query, transform: transform, batch_size: 6236 }.merge( options )

                if not self.__elasticsearch__.client.indices.exists index: index_name_lc
                    self.create_index( index_name_lc )
                end

                Rails.logger.debug( "importing index #{index_name_lc}" )
                self.importing options
            end

            break if no_loop
        end
    end
end

# notes:
# - provides a 'text' column