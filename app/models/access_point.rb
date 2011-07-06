class AccessPoint < ActiveRecord::Base
  require 'ipaddr'

  acts_as_authorization_object
  acts_as_mappable :default_units => :kms

  paginates_per 10
  CLUSTER_ACCESS_POINTS_WITHIN_KM = 2

  belongs_to :wisp
  has_one :property_set, :autosave => true, :dependent => :destroy
  has_many :activities
  has_many :activity_histories

  delegate :reachable, :to => :property_set, :allow_nil => true
  delegate :notes, :notes=, :site_description, :site_description=,
           :public, :public=,
           :to => :property_set, :allow_nil => true

  def coords
    [lat, lng]
  end

  def ip
    mng_ip.nil? ? nil : IPAddr.new(read_attribute(:mng_ip), Socket::AF_INET).to_s
  end

  def up?
    reachable == true
  end

  def down?
    reachable == false
  end

  def unknown?
    reachable.nil?
  end

  def known?
    !unknown?
  end

  def status
    if unknown?
      -1
    elsif up?
      1
    elsif down?
      0
    end
  end

  def reachable!
    set_reachable_to true
  end

  def unreachable!
    set_reachable_to false
  end

  def latest_seen
    unless unknown?
      latest = activity_histories.last :conditions => ["status > ?", 0], :order => "last_time ASC"
      latest.nil? ? '-' : latest.last_time
    end
  end

  def earliest_seen
    unless unknown?
      earliest = activity_histories.first :conditions => ["status > ?", 0], :order => "last_time ASC"
      earliest.nil? ? '-' : earliest.last_time
    end
  end

  def up_average(from, to)
    sprintf "%.1f", activity_histories.observe(activation_date > from ? activation_date : from, to).average_availability
  end

  def down_average(from, to)
    sprintf "%.1f", 100 - activity_histories.observe(activation_date > from ? activation_date : from, to).average_availability
  end

  def associated_users(scope = :all)
    AssociatedUser.active_resource_from(wisp.owmw_url, wisp.owmw_username, wisp.owmw_password)
    AssociatedUser.find(scope, :params => {:access_point => hostname})
  end


  ##### Static methods #####

  def self.draw_map
    clustered_access_points = []
    already_clustered = []

    find_each do |hs|
      cluster = around(hs.coords)
      cluster -= already_clustered

      clustered_access_points << ( cluster.count > 1 ? Cluster.new(cluster) : cluster.first )

      already_clustered += cluster
    end

    clustered_access_points
  end

  def self.of_wisp(wisp)
    # Skip scope (and let other scopes return results) if wisp is nil
    wisp ? where(:wisp_id => wisp.id) : scoped
  end

  def self.sort_with(attribute, direction)
    if attribute == 'status'
      with_properties.order("`reachable` #{direction}")
    else
      order("#{attribute} #{direction}")
    end
  end

  def self.around(coords)
    select("`access_points`.*").geo_scope(:within => CLUSTER_ACCESS_POINTS_WITHIN_KM, :origin => coords)
  end

  def self.on_georss
    with_properties.where(:property_sets => {:public => true})
  end

  def self.up
    with_properties.where(:property_sets => {:reachable => true})
  end

  def self.down
    with_properties.where(:property_sets => {:reachable => false})
  end

  def self.known
    with_properties.where(:property_sets => {:reachable => [true, false]})
  end

  def self.unknown
    with_properties.where(:property_sets => {:reachable => nil})
  end

  def self.activated(till=nil)
    where("activation_date <= ?", till)
  end

  def self.all_up(regex=nil)
    AccessPoint.up.hostname_like regex
  end

  def self.all_down(regex=nil)
    AccessPoint.down.hostname_like regex
  end

  def self.all_unknown(regex=nil)
    AccessPoint.unknown.hostname_like regex
  end

  def self.hostname_like(name)
    where("`hostname` LIKE ?", "%#{name}%")
  end

  private

  def self.with_properties
    joins("LEFT JOIN `property_sets` ON `property_sets`.`access_point_id` = `access_points`.`id`")
  end

  def set_reachable_to(boolean)
    property_set.update_attribute(:reachable, boolean) rescue PropertySet.create(:reachable => boolean, :access_point => self)
  end
end