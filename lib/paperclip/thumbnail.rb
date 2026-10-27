# frozen_string_literal: true

module Paperclip
  # Handles thumbnailing images that are uploaded.
  class Thumbnail < Processor
    attr_accessor :current_geometry, :target_geometry, :format, :whiny, :convert_options,
                  :source_file_options, :animated, :auto_orient, :frame_index

    # List of formats that we need to preserve animation
    ANIMATED_FORMATS = %w(gif).freeze
    MULTI_FRAME_FORMATS = %w(.mkv .avi .mp4 .mov .mpg .mpeg .gif).freeze

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
    #   +frame_index+ - the frame index of the source file to render as the thumbnail
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
      @convert_options     = @convert_options.split(/\s+/)     if @convert_options.respond_to?(:split)

      @current_format      = File.extname(@file.path)
      @basename            = File.basename(@file.path, @current_format)
      @frame_index         = multi_frame_format? ? options.fetch(:frame_index, 0) : 0
    end

    # Returns true if the +target_geometry+ is meant to crop.
    def crop?
      @crop
    end

    # Returns true if the image is meant to make use of additional convert options.
    def convert_options?
      !@convert_options.nil? && !@convert_options.empty?
    end

    # Returns crop coordinates supplied by the attachment's model, when that model
    # supports Paperclip's legacy explicit-crop API.
    def cropping?
      return false unless @attachment

      target = @attachment.instance
      return false unless target.respond_to?(:cropping?)

      if target.cropping?(processor_options_with_name)
        [target.crop_x.to_i, target.crop_y.to_i, target.crop_w.to_i, target.crop_h.to_i]
      else
        false
      end
    end

    # Performs the conversion of the +file+ into a thumbnail. Returns the Tempfile
    # that contains the new image.
    def make
      src = @file
      filename = [@basename, @format ? ".#{@format}" : ""].join
      dst = TempfileFactory.new.generate(filename)

      begin
        parameters = []
        parameters << source_file_options
        parameters << ":source"
        parameters << transformation_command
        parameters << convert_options
        parameters << ":dest"

        parameters = parameters.flatten.compact.join(" ").strip.squeeze(" ")

        frame = animated? ? "" : "[#{@frame_index}]"
        convert(
          parameters,
          source: "#{File.expand_path(src.path)}#{frame}",
          dest: File.expand_path(dst.path)
        )
      rescue Terrapin::ExitStatusError => e
        if @whiny
          message = "There was an error processing the thumbnail for #{@basename}:\n" + e.message
          raise Paperclip::Error, message
        end
      rescue Terrapin::CommandNotFoundError => e
        raise Paperclip::Errors::CommandNotFoundError.new("Could not run the `convert` command. Please install ImageMagick.")
      end

      dst
    end

    # Returns the command ImageMagick's +convert+ needs to transform the image
    # into the thumbnail.
    def transformation_command
      scale, crop = @current_geometry.transformation_to(@target_geometry, crop?)
      crop_coords = cropping?
      trans = []
      trans << "-coalesce" if animated?
      trans << "-auto-orient" if auto_orient
      if crop_coords
        trans.concat explicit_crop_command(crop_coords)
        trans << "-resize" << %["#{explicit_crop_resize_geometry}"] unless scale.nil? || scale.empty?
      else
        trans << "-resize" << %["#{scale}"] unless scale.nil? || scale.empty?
        trans << "-crop" << %["#{crop}"] << "+repage" if crop
      end
      trans.concat image_magick_transformation_commands(@options[:name] || @options[:style] || :original)
      trans << '-layers "optimize"' if animated?
      trans
    end

    def thumbnail_transformations(style_name)
      return {} unless @attachment&.respond_to?(:transform_commands)

      transformations = @attachment.transform_commands || {}
      transformations[style_name.to_sym] || transformations[:all] || {}
    end

    def image_magick_transformation_commands(style_name)
      thumbnail_transformations(style_name).flat_map do |command, params|
        next [] if params.nil? || params == false

        switch = image_magick_switch(command)
        params = [] if params == true
        [switch, *Array(params).map { |param| image_magick_argument(param) }]
      end
    end

    def image_magick_switch(command)
      command = command.to_s.tr("_", "-")
      command.start_with?("-", "+") ? command : "-#{command}"
    end

    def image_magick_argument(argument)
      case argument
      when String
        %["#{argument.gsub('"', '\\"')}"]
      when Symbol
        argument.to_s
      else
        argument.to_s
      end
    end

    def processor_options_with_name
      return @options if @options[:name] || !@options.key?(:style)

      @options.merge(name: @options[:style])
    end

    def explicit_crop_command(crop_coords)
      crop_x, crop_y, crop_w, crop_h = crop_coords
      ["-crop", %["#{crop_w}x#{crop_h}+#{crop_x}+#{crop_y}"], "+repage"]
    end

    def explicit_crop_resize_geometry
      @target_geometry.to_s.sub(/[#!<>@^]\z/, "")
    end

    protected

    def multi_frame_format?
      MULTI_FRAME_FORMATS.include? @current_format
    end

    def animated?
      @animated && (ANIMATED_FORMATS.include?(@format.to_s) || @format.blank?) && identified_as_animated?
    end

    # Return true if ImageMagick's +identify+ returns an animated format
    def identified_as_animated?
      if @identified_as_animated.nil?
        @identified_as_animated = ANIMATED_FORMATS.include? identify("-format %m :file", file: "#{@file.path}[0]").to_s.downcase.strip
      end
      @identified_as_animated
    rescue Terrapin::ExitStatusError => e
      raise Paperclip::Error, "There was an error running `identify` for #{@basename}" if @whiny
    rescue Terrapin::CommandNotFoundError => e
      raise Paperclip::Errors::CommandNotFoundError.new("Could not run the `identify` command. Please install ImageMagick.")
    end
  end
end
