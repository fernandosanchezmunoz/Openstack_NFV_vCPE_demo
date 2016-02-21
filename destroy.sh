#!/bin/bash
#Author: Fernando Sanchez (fernando at plumgrid dot com)
#(c)2016 Fernando Sanchez and PLUMgrid inc.
#Script to destroy a full NFV environment in Openstack. This includes external connectivity, a purpose-built tenant,
#and a two stage routed environment with a Network_WAN-Router-Network_out-[NFV]-Network_in-Router-Network_METRO topology.
#Check Network diagram for details.

#Read environment variables from the resource file. Check resource file for details
export ENVIRONMENT_PATH="./nfvrc"
. $ENVIRONMENT_PATH

#Check Keystone authentication and existing ADMIN user
if [ "$ADMIN_NAME" = $(keystone tenant-list|grep $ADMIN_NAME|awk -F '|' '{print $3}'| tr -d ' ') ]
then
	echo "Keystone connection and credentials OK."
else
	echo "Keystone connection incorrect. Please check address and credentials  in "$ENVIRONMENT_PATH" file and try again. Exiting."
	exit 0
fi

#Clear default route from router-in
neutron router-update $rtr_in_name --routes action=clear
sleep 1

#Delete RTR-in 
neutron router-interface-delete $rtr_in_name $NFV_subnet_in_name
sleep 1
neutron router-interface-delete $rtr_in_name $METRO_subnet_name
sleep 1
neutron router-delete $rtr_in_name
sleep 1

#Authenticate as the NFV tenant to handle VNFs
export OS_TENANT_NAME=$NFV_tenant_name
export OS_PROJECT_NAME=$NFV_tenant_name 
export OS_USERNAME=$NFV_tenant_name 
export OS_PASSWORD=$NFV_tenant_name 

#Delete VNF#1
nova delete $VNF_1_name
sleep 5
#Delete VNF#2
nova delete $VNF_2_name
sleep 5

#Authenticate as Admin
export OS_TENANT_NAME=$ADMIN_NAME
export OS_USERNAME=$ADMIN_NAME
export OS_PASSWORD=$ADMIN_PASSWORD

#Delete VNF1s ports
neutron port-delete $VNF_1_port_1_id
neutron port-delete $VNF_1_port_2_id

#Delete VNF2s ports
neutron port-delete $VNF_2_port_1_id
neutron port-delete $VNF_2_port_2_id

#Delete METRO net and subnet
neutron subnet-delete $METRO_subnet_name
neutron net-delete $METRO_net_name
sleep 1

#Delete NFV_in net and subnet
neutron subnet-delete $NFV_subnet_in_name
neutron net-delete $NFV_net_in_name
sleep 1

#Delete RTR_out
neutron router-interface-delete $rtr_out_name $NFV_subnet_out_name
neutron router-gateway-clear $rtr_out_name
sleep 3
neutron router-delete $rtr_out_name
sleep 1

#Delete net_out and subnet_out
neutron subnet-delete $NFV_subnet_out_name
neutron net-delete $NFV_net_out_name

#Delete NFV tenant
keystone user-delete $NFV_tenant_name
keystone tenant-delete $NFV_tenant_name
sleep 1

#Delete external connectivity: WAN_net and subnet
neutron subnet-delete $WAN_subnet_name
neutron net-delete $WAN_net_name
sleep 3

#Delete default security group with all rules
neutron security-group-delete $default_secgroup_id

echo "Done! Environment deleted."
