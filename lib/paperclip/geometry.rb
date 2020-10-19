module Paperclip

  # Defines the geometry of an image.
  class Geometry
    attr_accessor :height, :width, :modifier

    # Gives a Geometry representing the given height and width
    def initialize width = nil, height = nil, modifier = nil
      @height = height.to_f
      @width  = width.to_f
      @modifier = modifier
    end

    # Uses ImageMagick to determing the dimensions of a file, passed in as either a
    # File or path.
    def self.from_file file
      file = file.path if file.respond_to? "path"
      raise(Paperclip::NotIdentifiedByImageMagickError.new("Cannot find the geometry of a file with a blank name")) if file.blank?
      geometry = begin
                   Paperclip.run("identify", "-format %wx%h :file", :file => "#{file}[0]")
                 rescue Cocaine::ExitStatusError
                   ""
                 rescue Cocaine::CommandNotFoundError => e
                   raise Paperclip::CommandNotFoundError.new("Could not run the `identify` command. Please install ImageMagick.")
                 end
      parse(geometry) ||
        raise(NotIdentifiedByImageMagickError.new("#{file} is not recognized by the 'identify' command."))
    end

    # Parses a "WxH" formatted string, where W is the width and H is the height.
    def self.parse string
      if match = (string && string.match(/\b(\d*)x?(\d*)\b([\>\<\#\@\%^!])?/i))
        Geometry.new(*match[1,3])
      end
    end

    # True if the dimensions represent a square
    def square?
      height == width
    end

    # True if the dimensions represent a horizontal rectangle
    def horizontal?
      height < width
    end

    # True if the dimensions represent a vertical rectangle
    def vertical?
      height > width
    end

    # The aspect ratio of the dimensions.
    def aspect
      width / height
    end

    # Returns the larger of the two dimensions
    def larger
      [height, width].max
    end

    # Returns the smaller of the two dimensions
    def smaller
      [height, width].min
    end

    # Returns the width and height in a format suitable to be passed to Geometry.parse
    def to_s
      s = ""
      s << width.to_i.to_s if width > 0
      s << "x#{height.to_i}" if height > 0
      s << modifier.to_s
      s
    end

    # Same as to_s
    def inspect
      to_s
    end

    # Returns the scaling and cropping geometries (in string-based ImageMagick format)
    # neccessary to transform this Geometry into the Geometry given. If crop is true,
    # then it is assumed the destination Geometry will be the exact final resolution.
    # In this case, the source Geometry is scaled so that an image containing the
    # destination Geometry would be completely filled by the source image, and any
    # overhanging image would be cropped. Useful for square thumbnail images. The cropping
    # is weighted at the center of the Geometry.
    def transformation_to dst, crop = false
      if crop
        ratio = Geometry.new( dst.width / self.width, dst.height / self.height )
        scale_geometry, scale = scaling(dst, ratio)
        crop_geometry         = cropping(dst, ratio, scale)
      else
        scale_geometry        = dst.to_s
      end

      [ scale_geometry, crop_geometry ]
    end

    def gifsicle_scaling dst, ratio
      if ratio.horizontal? || ratio.square?
        [ ("%dx%d" % [dst.width, dst.height]), ratio.width ]
      else
        [ ("%dx%d" % [dst.width, dst.height]), ratio.height ]
      end
    end

    #gifsicle -O2 --crop #{crop} --resize #{scale} #{test_thumb} -o /tmp/gif.gif
    def gifsicle_transformation_to dst, crop = false
      if crop
        ratio = Geometry.new( dst.width / self.width, dst.height / self.height )
        scale_geometry, scale = gifsicle_scaling(dst, ratio)
        crop_geometry         = gifsicle_cropping(dst, ratio, scale)
      else
        scale_geometry        = dst.to_s
      end
      [ scale_geometry, crop_geometry ]
    end

    private

    # ported from Wordpress image_resize_dimensions
    def gifsicle_cropping dst, ratio, scale
      #if ratio.horizontal? || ratio.square?
      orig_h = height
      orig_w = width
      #puts [orig_w, orig_h].join('x')
      aspect_ratio = orig_w.to_f / orig_h.to_f
      new_w        = [dst.width, orig_w].min
      new_h        = [dst.height, orig_h].min
      new_w = ( new_h * aspect_ratio ).ceil if new_w.zero?
      new_h = [new_w / aspect_ratio].min if new_h.zero?
      #puts [new_w, new_h].join('x')
      size_ratio = [ new_w.to_f / orig_w.to_f, new_h.to_f / orig_h.to_f ].max
      #puts "size_ratio: #{size_ratio.to_f}"
      crop_h = ( new_h.to_f / size_ratio ).ceil
      crop_w = ( new_w.to_f / size_ratio ).ceil
      #puts "CORP: #{[crop_w, crop_h].join('x')}"
      s_x = ( ( orig_w - crop_w ) / 2 ).floor
      s_y = ( ( orig_h - crop_h ) / 2 ).floor
      #// int dst_x, int dst_y, int src_x, int src_y, int dst_w, int dst_h, int src_w, int src_h
      r = { dst_x: 0, dst_y: 0, src_x: s_x, src_y: s_y, dst_w: new_w, dst_h: new_h, src_w: crop_w, src_h: crop_h }
      Rails.logger.debug "gifsicle_cropping: #{r.inspect}"
      #"%d,%d+%dx%d" % [  r[:src_x], r[:src_y], (r[:src_w] - r[:src_x]), (r[:src_h] - r[:src_y]) ]
      "%d,%d+%dx%d" % [  r[:src_x], r[:src_y], r[:src_w] , r[:src_h] ]
    end


    def scaling dst, ratio
      if ratio.horizontal? || ratio.square?
        [ "%dx" % dst.width, ratio.width ]
      else
        [ "x%d" % dst.height, ratio.height ]
      end
    end

    def cropping dst, ratio, scale
      if ratio.horizontal? || ratio.square?
        "%dx%d+%d+%d" % [ dst.width, dst.height, 0, (self.height * scale - dst.height) / 2 ]
      else
        "%dx%d+%d+%d" % [ dst.width, dst.height, (self.width * scale - dst.width) / 2, 0 ]
      end
    end
  end
end
