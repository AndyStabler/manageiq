module Mixins
  module GenericButtonMixin
    # handle buttons pressed on the button bar
    def button
      @edit = session[:edit] # Restore @edit for adv search box
      params[:display] = @display if %w(images instances).include?(@display) # Were we displaying vms/hosts/storages
      params[:page] = @current_page unless @current_page.nil? # Save current page for list refresh

      # Handle buttons from sub-items screen
      if params[:pressed].starts_with?("image_",
                                       "instance_")

        pfx = pfx_for_vm_button_pressed(params[:pressed])
        process_vm_buttons(pfx)

        # Control transferred to another screen, so return
        return if ["#{pfx}_policy_sim", "#{pfx}_compare", "#{pfx}_tag",
                   "#{pfx}_retire", "#{pfx}_protect", "#{pfx}_ownership",
                   "#{pfx}_refresh", "#{pfx}_right_size",
                   "#{pfx}_reconfigure"].include?(params[:pressed]) &&
                  @flash_array.nil?

        unless ["#{pfx}_edit", "#{pfx}_miq_request_new", "#{pfx}_clone",
                "#{pfx}_migrate", "#{pfx}_publish"].include?(params[:pressed])
          @refresh_div = "main_div"
          @refresh_partial = "layouts/gtl"
          show # Handle VMs buttons
        end
      elsif params[:pressed].ends_with?("_tag")
        case params[:pressed]
        when "#{self.class.table_name}_tag" then tag(self.class.model)
        when "cloud_subnet_tag"             then tag(CloudSubnet)
        when "floating_ip_tag"              then tag(FloatingIp)
        when "load_balancer_tag"            then tag(LoadBalancer)
        when "network_port_tag"             then tag(NetworkPort)
        when "network_router_tag"           then tag(NetworkRouter)
        when "security_group_tag"           then tag(SecurityGroup)
        end

        return if @flash_array.nil?
      end

      check_if_button_is_implemented

      if params[:pressed].ends_with?("_edit") || ["#{pfx}_miq_request_new", "#{pfx}_clone",
                                                  "#{pfx}_migrate", "#{pfx}_publish"].include?(params[:pressed])
        render_or_redirect_partial(pfx)
      elsif @refresh_div == "main_div" && @lastaction == "show_list"
        replace_gtl_main_div
      else
        render_flash
      end
    end
  end
end
