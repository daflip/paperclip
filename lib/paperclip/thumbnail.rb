# frozen_string_literal: true

module Paperclip
  # Handles thumbnailing images that are uploaded.
  class Thumbnail < Processor
    attr_accessor :current_geometry, :target_geometry, :format, :whiny, :convert_options,
                  :source_file_options, :animated, :auto_orient, :frame_index

    ANIMATED_FORMATS = %w[gif].freeze
    MULTI_FRAME_FORMATS = %w[.mkv .avi .mp4 .mov .mpg .mpeg .gif].freeze

    def initialize(file, options = {}, attachment = nil)
      super

      geometry             = options[:geometry].to_s
      @crop                = geometry[-1, 1] == "#"
      @target_geometry     = options.fetch(:string_geometry_parser, Geometry).parse(geometry)
      @current_geometry    = options.fetch(:file_geometry_parser, Geometry).from_file(@file)
      @source_file_options = options[:source_file_options]
      @convert_options     = options[:convert_options]
      @whiny               = options.fetch(:whiny, true)
      @format              = options[:format]
      @animated            = options.fetch(:animated, true)
      @auto_orient         = options.fetch(:auto_orient, true)
      @current_geometry.auto_orient if @auto_orient && @current_geometry.respond_to?(:auto_orient)
      @source_file_options = @source_file_options.split(/\s+/) if @source_file_options.respond_to?(:split)
      @convert_options     = @convert_options.split(/\s+/) if @convert_options.respond_to?(:split)

      @current_format      = File.extname(@file.path)
      @basename            = File.basename(@file.path, @current_format)
      @frame_index         = multi_frame_format? ? options.fetch(:frame_index, 0) : 0
    end

    def crop?
      @crop
    end

    def convert_options?
      !@convert_options.nil? && !@convert_options.empty?
    end

    def cropping?
      return false unless @attachment

      target = @attachment.instance
      if target.respond_to?(:cropping?) && target.cropping?(@options)
        [target.crop_x.to_i, target.crop_y.to_i, target.crop_w.to_i, target.crop_h.to_i]
      else
        false
      end
    end

    def gifsicle_make
      dst = TempfileFactory.new.generate([@basename, @format ? ".#{@format}" : ""].join)

      parameters = [
        "-O2",
        "--conserve-memory",
        gifsicle_transformation_command,
        ":source",
        "-o :dest"
      ].flatten.compact.join(" ").strip.squeeze(" ")

      Paperclip.run(
        "gifsicle",
        parameters,
        source: "#{File.expand_path(@file.path)}#{'[0]' unless animated?}",
        dest: File.expand_path(dst.path)
      )
      dst
    rescue Terrapin::ExitStatusError => e
      raise Paperclip::Error, "There was an error processing the thumbnail for #{@basename}:\n#{e.message}" if @whiny
    rescue Terrapin::CommandNotFoundError
      raise Paperclip::Errors::CommandNotFoundError.new("Could not run the `gifsicle` command. Please install gifsicle.")
    end

    def preserve_animation?
      @attachment&.instance&.respond_to?(:animated?) && @attachment.instance.animated?
    end

    def thumbnail_transformations(style_name)
      return {} unless @attachment&.vips_transforms

      @attachment.vips_transforms[style_name] || @attachment.vips_transforms[:all] || {}
    end

    def make
      style_name = @options[:name] ? @options[:name].to_sym : :original
      src = @file
      original_file_ext = File.extname(src.path).downcase.gsub(/[^a-z0-9]/, "")
      ext = @format.present? ? ".#{@format}" : ".#{original_file_ext}"
      actual_ext = ext
      ext = ".jpg" if %w[.jpeg .pdf .tiff .tif .bmp].include?(ext)

      if ext == ".gif" && preserve_animation?
        @format = "gif"
        return gifsicle_make
      end

      dst = TempfileFactory.new.generate([@basename, ext].join)
      result = ImageProcessing::Vips.source(@attachment&.vips_image || src)
      options = Array(convert_options).flatten.join(" ")

      result = result.saver(quality: Regexp.last_match(1).to_i, strip: options.include?("-strip")) if options.match(/-quality ["']?(\d+)["']?/)
      result = result.crop(*crop_coords) if (crop_coords = cropping?)

      if (scale = scale_params)
        result = if crop? || cropping?
                   result.resize_to_fit(*scale)
                 else
                   result.resize_to_limit(*scale)
                 end
      end

      thumbnail_transformations(style_name).each do |method, params|
        result = result.public_send(method, *params)
      end

      if actual_ext != ext
        result = result.convert("jpg")
        result = result.colourspace(:srgb)
      end

      result.call(destination: dst.path)
      dst
    rescue StandardError => e
      raise Paperclip::Error, "There was an error processing the thumbnail for #{@basename}: #{e.message}" if @whiny
    end

    def scale_params
      scale, = @current_geometry.transformation_to(@target_geometry, crop?)
      return false if scale.nil? || scale.empty?

      params = []
      options = {}

      params << @target_geometry.width.to_i
      params << @target_geometry.height.to_i
      options[:crop] = :attention if crop? && !cropping?

      params << options
      params
    end

    def gifsicle_thumbnail_transformations(style_name)
      transformations = []
      if (degrees = thumbnail_transformations(style_name)[:rotate])
        transformations << "--rotate-#{degrees == 90 ? 90 : 270}"
      end
      transformations
    end

    def gifsicle_transformation_command
      scale, crop = @current_geometry.gifsicle_transformation_to(@target_geometry, crop?)
      transformations = []

      transformations << "--crop" << %("#{crop}") if crop
      if scale.present?
        thumb_scale = scale.to_s.gsub(/\W/, "")
        transformations << "--resize-colors 64"
        transformations << "--#{crop ? 'resize' : 'resize-fit'}" << %("#{thumb_scale}")
      end
      transformations + gifsicle_thumbnail_transformations(@options[:name])
    end

    protected

    def multi_frame_format?
      MULTI_FRAME_FORMATS.include? @current_format
    end

    def animated?
      @animated && ANIMATED_FORMATS.include?(@current_format.delete_prefix(".")) && (ANIMATED_FORMATS.include?(@format.to_s) || @format.blank?)
    end
  end
end
