module Paperclip
  # Handles thumbnailing images that are uploaded.
  class Thumbnail < Processor

    attr_accessor :current_geometry, :target_geometry, :format, :whiny, :convert_options,
                  :source_file_options, :animated

    # List of formats that we need to preserve animation
    ANIMATED_FORMATS = %w(gif)

    # Creates a Thumbnail object set to work on the +file+ given. It
    # will attempt to transform the image into one defined by +target_geometry+
    # which is a "WxH"-style string. +format+ will be inferred from the +file+
    # unless specified. Thumbnail creation will raise no errors unless
    # +whiny+ is true (which it is, by default. If +convert_options+ is
    # set, the options will be appended to the convert command upon image conversion
    #
    # Options include:
    #
    #   +geometry+ - the desired width and height of the thumbnail (required)
    #   +file_geometry_parser+ - an object with a method named +from_file+ that takes an image file and produces its geometry and a +transformation_to+. Defaults to Paperclip::Geometry
    #   +string_geometry_parser+ - an object with a method named +parse+ that takes a string and produces an object with +width+, +height+, and +to_s+ accessors. Defaults to Paperclip::Geometry
    #   +source_file_options+ - flags passed to the +convert+ command that influence how the source file is read
    #   +convert_options+ - flags passed to the +convert+ command that influence how the image is processed
    #   +whiny+ - whether to raise an error when processing fails. Defaults to true
    #   +format+ - the desired filename extension
    #   +animated+ - whether to merge all the layers in the image. Defaults to true
    def initialize(file, options = {}, attachment = nil)
      super

      geometry             = options[:geometry] # this is not an option
      @file                = file
      @crop                = geometry[-1,1] == '#'
      @target_geometry     = (options[:string_geometry_parser] || Geometry).parse(geometry)
      @current_geometry    = (options[:file_geometry_parser] || Geometry).from_file(@file)
      @source_file_options = options[:source_file_options]
      @convert_options     = options[:convert_options]
      @whiny               = options[:whiny].nil? ? true : options[:whiny]
      @format              = options[:format]
      @animated            = options[:animated].nil? ? true : options[:animated]

      @source_file_options = @source_file_options.split(/\s+/) if @source_file_options.respond_to?(:split)
      @convert_options     = @convert_options.split(/\s+/)     if @convert_options.respond_to?(:split)

      @current_format      = File.extname(@file.path)
      @basename            = File.basename(@file.path, @current_format)

    end

    # Returns true if the +target_geometry+ is meant to crop.
    def crop?
      @crop
    end

    # Returns true if the image is meant to make use of additional convert options.
    def convert_options?
      !@convert_options.nil? && !@convert_options.empty?
    end

    def cropping?
      return false unless @attachment
      target = @attachment.instance
      if target.respond_to?(:cropping?) and target.cropping?(@options)
        # params are in the order vips_crop requires;
        [ target.crop_x.to_i, target.crop_y.to_i, target.crop_w.to_i, target.crop_h.to_i ]
      else
        false
      end
    end

    # gifsicle adapted make, especially for resizing GIF images
    def gifsicle_make
      src = @file
      dst = Tempfile.new([@basename, @format ? ".#{@format}" : ''])
      dst.binmode
      begin
        parameters = ['-O2', '--conserve-memory']
        #parameters << source_file_options
        parameters << gifsicle_transformation_command
        parameters << ':source'
        #parameters << convert_options
        parameters << '-o :dest'
        parameters = parameters.flatten.compact.join(" ").strip.squeeze(" ")
        #Rails.logger.debug "#{@attachment.instance.id} gifsicle: #{src.path} -> #{parameters.inspect} for -> #{dst.path}"
        success = Paperclip.run("gifsicle", parameters, source: "#{File.expand_path(src.path)}#{'[0]' unless animated?}", dest: File.expand_path(dst.path))
      rescue Cocaine::ExitStatusError => e
        Rails.logger.error "Error processing #{@basename}: #{$!}"
        raise PaperclipError, "There was an error processing the thumbnail for #{@basename}" if @whiny
      rescue Cocaine::CommandNotFoundError => e
        raise Paperclip::CommandNotFoundError.new("Could not run the `convert` command. Please install ImageMagick.")
      end
      dst
    end

    def preserve_animation?
      @attachment.instance.respond_to?(:animated?) and @attachment.instance.try(:animated?) 
    end

    # Performs the conversion of the +file+ into a thumbnail. Returns the Tempfile
    # that contains the new image.
    def make
      style_name = @options[:name] ? @options[:name].to_sym : :original
      src = @file
      original_file_ext = File.extname(src.path).downcase.gsub(/[^a-z0-9]/,"")
      ext = (@format && @format.present?) ? ".#{@format}"  : ".#{original_file_ext}"
      actual_ext = ext
      # force convert to jpg
      ext = '.jpg' if %w(.jpeg .pdf .tiff .tif .bmp ).include?(ext)
      begin
        # if this is a gif and we're meant to retain animation
        if ext == '.gif' and preserve_animation?
          @format = 'gif'
          return gifsicle_make 
        end
        dst = Tempfile.new([@basename, ext])
        dst.binmode

        result = ImageProcessing::Vips
        result = result.source(@attachment ? @attachment.vips_image : src)
        c = convert_options.flatten.join(' ')

        # grep quality from command line
        result = result.saver(quality: $1.to_i, strip: c.include?('-strip')) if c.match(/-quality ["']?(\d+)["']?/)

        # apply cropping 
        if crop_coords = cropping?
          result = result.crop(*crop_coords) 
        end

        # if we have scaling params
        if s = scale_params
          # then resize to fit if we're cropping
          result = if crop? or cropping?
            result.resize_to_fit(*s) 
          else # otherwise resize gracefully (without cropping or upsizing)
            result.resize_to_limit(*s)  
          end
        end
        if @attachment and @attachment.vips_transforms and (@attachment.vips_transforms[style_name] || @attachment.vips_transforms[:all])
          (@attachment.vips_transforms[ style_name ] || @attachment.vips_transforms[:all]).each do |method, params|
            Rails.logger.info "Applying #{style_name} transform: #{method} with #{params}"
            result = result.send(method, *params)
          end
        end
        if actual_ext != ext
          Rails.logger.info "Converting #{ext} to .JPG"
          result = result.convert("jpg")
          result = result.colourspace(:srgb)
        end
        #raise result.inspect
        result.call(destination: dst.path)
        return dst
      rescue #Cocaine::ExitStatusError => e
        if Rails.env.production?
          raise PaperclipError, "There was an error processing the thumbnail for #{@basename}" if @whiny
        else
          raise PaperclipError, "There was an error processing the thumbnail for #{@basename}: #{$!}" 
        end
      end

      dst
    end

    def scale_params
      scale, crop = @current_geometry.transformation_to(@target_geometry, crop?)
      r = []
      opts = {}
      unless scale.nil? || scale.empty?
        r << @target_geometry.width.to_i
        r << @target_geometry.height.to_i
        # use smartcrop if we're meant to crop but we're not explicitly cropping coordinates
        opts[:crop] = :attention if crop? and (not cropping?)#c == '#'
      end
      # perceptual colorspacin'
      #opts[:intent] = :perceptual
      r << opts
      #raise r.inspect
      # if scale.match(/\A(\d+)x(\d+)(.?)\Z/)
      #   w,h,c = [$1,$2,$3]
      #   r << w.to_i
      #   r << h.to_i
      #   r << {crop: :attention } if crop?#c == '#'
      #    #raise r.inspect
      #   #[trans << "-resize" << %["#{scale}"] 
      # else 
      #   raise "failed to parse scale: #{scale}"
      # end
      #end
      r.any? ? r : false
    end

    # imagemagick based crop to gifsicle crop format
    # $src_x,
    # $src_y,
    # $src_w - $src_x,
    # $src_h - $src_y
    #def gifsicle_crop(image_magick_crop_string)
    #  Rails.logger.debug "transforming imagemagick crop: #{image_magick_crop_string}"
    #  return image_magick_crop_string
    #  if r = image_magick_crop_string.match(/\A(\d+)x(\d+)\+(\d+)\+(\d+)\Z/)
    #    # w-h-y-x -> x,y+WxH
    #    "%d,%d+%dx%d" % [ r[4], r[3], r[1], r[2] ]
    #  else
    #    raise "unable to convert imagemagick crop string!"
    #  end
    #end

    # Returns the command GIFSICLE +convert+ needs to transform the image
    # into the thumbnail.
    def gifsicle_transformation_command
      scale, crop = @current_geometry.gifsicle_transformation_to(@target_geometry, crop?)
      trans = []

      trans << "--crop" << %["#{crop}"] if crop 
      #trans << "-coalesce" if animated?
      if scale.present?
        #Rails.logger.debug "scaling: #{scale.inspect} dst: #{@target_geometry.to_s}"
        thumb_scale = scale.to_s.gsub(/\W/, "")
        #thumb_scale = @target_geometry.to_s.gsub(/\W/, "")
        # gifsicle params:
        trans << "--resize-colors 64"
        # if we're cropping we're resizing the image
        # otherwise we're just fitting within the specified size..
        trans << "--#{crop ? 'resize' : 'resize-fit' }" << %["#{thumb_scale}"] 
      end
      #trans << "-crop" << %["#{crop}"] << "+repage" if crop and (not is_animation)
      Rails.logger.debug "transformation command: #{trans.join(' ')}"
      trans
    end

    protected

    # Return true if the format is animated
    def animated?
      @animated && ANIMATED_FORMATS.include?(@current_format[1..-1]) && (ANIMATED_FORMATS.include?(@format.to_s) || @format.blank?)
    end
  end
end
