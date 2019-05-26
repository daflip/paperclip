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

    # Performs the conversion of the +file+ into a thumbnail. Returns the Tempfile
    # that contains the new image.
    def make
      src = @file
      original_file_ext = File.extname(src.path).downcase.gsub(/[^a-z0-9]/,"")
      ext = (@format && @format.present?) ? ".#{@format}"  : ".#{original_file_ext}"
      actual_ext = ext
      # force convert to jpg
      ext = '.jpg' if %w(.jpeg .pdf .tiff .tif .bmp ).include?(ext)
      dst = Tempfile.new([@basename, ext])
      dst.binmode
      begin
				result = ImageProcessing::Vips
        #Rails.logger.info @attachment.inspect
        #Rails.logger.info @attachment.vips_image.inspect
				result = result.source(@attachment ? @attachment.vips_image : src)
        #Rails.logger.debug "Checking convert_options"
        c = convert_options.flatten.join(' ')
        #Rails.logger.debug c.inspect

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
        #if c.include?('-strip')
        #Rails.logger.debug "doing strip.."
        #result = result.strip 
        #Rails.logger.debug "did strip.."
        #end
        if @attachment and @attachment.vips_transforms
          @attachment.vips_transforms.each do |method, params|
            Rails.logger.info "Applying transform: #{method} with #{params}"
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
			#	if scale.match(/\A(\d+)x(\d+)(.?)\Z/)
			#		w,h,c = [$1,$2,$3]
			#		r << w.to_i
			#		r << h.to_i
			#		r << {crop: :attention } if crop?#c == '#'
      #    #raise r.inspect
			#		#[trans << "-resize" << %["#{scale}"] 
			#	else 
			#		raise "failed to parse scale: #{scale}"
			#	end
			#end
      r.any? ? r : false
		end

    # Returns the command ImageMagick's +convert+ needs to transform the image
    # into the thumbnail.
    #def transformation_command
    #  scale, crop = @current_geometry.transformation_to(@target_geometry, crop?)
    #  trans = []
    #  trans << "-coalesce" if animated?
    #  trans << "-resize" << %["#{scale}"] unless scale.nil? || scale.empty?
    #  trans << "-crop" << %["#{crop}"] << "+repage" if crop
    #  trans
    #end

    protected

    # Return true if the format is animated
    def animated?
      @animated && ANIMATED_FORMATS.include?(@current_format[1..-1]) && (ANIMATED_FORMATS.include?(@format.to_s) || @format.blank?)
    end
  end
end
