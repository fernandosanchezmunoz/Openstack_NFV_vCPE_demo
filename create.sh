#!/bin/bash
#Author: Fernando Sanchez (fernando at plumgrid dot com)
#(c)2016 Fernando Sanchez and PLUMgrid inc.
#Script to create a full NFV environment in Openstack. This includes external connectivity, a purpose-built tenant,
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

#Check for VNF images existing in Glance, create otherwise
if [ "$VNF_1_image" = $(glance image-list|grep $VNF_1_image|awk -F '|' '{print $3}'| tr -d ' ') ]
then
	echo "VNF1 Image exists..."
else
	echo "Creating VNF1 Image..."
	if [ ! -f $VNF_1_file ]; then
		wget -O ./$VNF_1_file $VNF_1_location
        fi 	
	glance image-create --name $VNF_1_image --is-public True --disk-format qcow2 --container-format bare --progress --file $VNF_1_file
fi

if [ "$VNF_2_image" = $(glance image-list|grep $VNF_2_image|awk -F '|' '{print $3}'| tr -d ' ') ]
then
	echo "VNF2 Image exists..."
else
	echo "Creating VNF2 Image..."
	if [ ! -f $VNF_2_file ]; then
		wget -O ./$VNF_2_file $VNF_2_location
        fi 	
	glance image-create --name $VNF_2_image --is-public True --disk-format qcow2 --container-format bare --progress --file $VNF_2_file
fi

#Create WAN-net
echo "Creating WAN network..."
#Check whether we're on a flat or vlan network and create accordingly
if [ "$WAN_net_type" = "vlan" ]
then
	neutron net-create --router:external --provider:physical_network=$WAN_net_physical_port \
		--provider:network_type="vlan" --provider:segmentation_id=$WAN_net_vlan_id \
		$WAN_net_name
	echo "WAN net created as VLAN "$WAN_net_vlan_id" on port "$WAN_net_physical_port
else
        neutron net-create --router:external --provider:physical_network=$WAN_net_physical_port \
                --provider:network_type="flat" \
                $WAN_net_name
        echo "WAN net created as flat on port "$WAN_net_physical_port
fi
sleep 1
#CREATE WAN-subnet
echo "Creating WAN subnet..."
neutron subnet-create --gateway-ip=$WAN_subnet_gw --allocation-pool start=$WAN_subnet_dhcp_start,end=$WAN_subnet_dhcp_end \
--dns-nameserver $WAN_subnet_dns --disable-dhcp --name $WAN_subnet_name $WAN_net_name $WAN_subnet_cidr
sleep 1

#CREATE NFV tenant
echo "Creating NFV tenant..."
keystone tenant-create --name=$NFV_tenant_name
#Get NFV tenant-id
export NFV_tenant_id=$(keystone tenant-get $NFV_tenant_name|grep "id"|awk -F '|' '{print $3}')
echo "NFV tenant created. Id is: "$NFV_tenant_id
sleep 1

#CREATE NFV user
echo "Creating NFV user and adding him and Admin to the NFV project..."
keystone user-create --name $NFV_tenant_name --tenant $NFV_tenant_name --pass $NFV_tenant_name
#automatically the user is member of the NFV project, so this is redundant
#openstack role add --user $NFV_tenant_name --project $NFV_tenant_id $member_role_name
#assign "admin" user to project
keystone user-role-add --user admin --tenant $NFV_tenant_id --role $member_role_name
sleep 1

#CREATE NFV-net-out
echo "Creating NFV outside network..."
neutron net-create --tenant-id $NFV_tenant_id $NFV_net_out_name
sleep 1

#Create NFV-subnet-out
echo "Creating NFV outside subnet..."
neutron subnet-create --tenant-id $NFV_tenant_id --name $NFV_subnet_out_name --gateway $NFV_subnet_out_gw --enable-dhcp --allocation-pool \
start=$NFV_subnet_out_dhcp_range_start,end=$NFV_subnet_out_dhcp_range_end --dns-nameserver $WAN_subnet_dns $NFV_net_out_name $NFV_subnet_out_cidr
sleep 1

#Create router-out
echo "Creating NFV outside router..."
neutron router-create --tenant-id $NFV_tenant_id $rtr_out_name
sleep 1
#Add interface to router on WAN-subnet (dhcp)
echo "Setting the gateway on the NFV outside router..."
neutron router-gateway-set $rtr_out_name $WAN_net_name
sleep 3
#Add interface to router on subnet-out
echo "Adding interface to outside router on NFV outside network..."
neutron router-interface-add $rtr_out_name $NFV_subnet_out_name
sleep 1

#Create NFV-net-in
echo "Creating NFV inside network..."
neutron net-create --tenant-id $NFV_tenant_id $NFV_net_in_name
sleep 1
#Create NFV-subnet-in
echo "Creating NFV inside subnet..."
neutron subnet-create --tenant-id $NFV_tenant_id --name $NFV_subnet_in_name --gateway $NFV_subnet_in_gw --enable-dhcp --allocation-pool \
start=$NFV_subnet_in_dhcp_range_start,end=$NFV_subnet_in_dhcp_range_end --dns-nameserver $WAN_subnet_dns $NFV_net_in_name $NFV_subnet_in_cidr
sleep 1

#Create METRO-net
echo "Creating METRO network..."
neutron net-create --tenant-id $NFV_tenant_id $METRO_net_name
sleep 1
#Create METRO-subnet
echo "Creating METRO subnet..."
neutron subnet-create --tenant-id $NFV_tenant_id --name $METRO_subnet_name --gateway $METRO_subnet_gw --disable-dhcp \
--dns-nameserver $WAN_subnet_dns $METRO_net_name $METRO_subnet_cidr
sleep 1


#Create VNFs - can be created by creating ports then adding to VNF, or by adding VNF directly to subnets
#This uses the "port" method, but the "subnet" method is left below for reference

echo "Creating VNF #1 ports..."
#Port Method to create VNF and pin it to a specific net and IP address. 
#Create ports on subnets with specific IP, then create Instance with those ports.
#Create port #1 for VNF #1 and get its id
export VNF_1_port_1_id=$(neutron port-create $NFV_net_out_name \
 --tenant-id $NFV_tenant_id \
 --fixed-ip subnet-id=$NFV_subnet_out_name,ip_address=$VNF_1_ip_1 \
 |grep " id "|awk -F '|' '{print $3}'| tr -d ' ')
#Add this port to the environment variables for use at "destroy" time
echo  "export VNF_1_port_1_id=$VNF_1_port_1_id" >> $ENVIRONMENT_PATH
#Create port #2 for VNF #1 and get its id
export VNF_1_port_2_id=$(neutron port-create $NFV_net_in_name \
 --tenant-id $NFV_tenant_id \
 --fixed-ip subnet-id=$NFV_subnet_in_name,ip_address=$VNF_1_ip_2 \
 |grep " id "|awk -F '|' '{print $3}'| tr -d ' ')
#Add this port to the environment variables for use at "destroy" time
echo  "export VNF_1_port_2_id=$VNF_1_port_2_id" >> $ENVIRONMENT_PATH

echo "Creating VNF #2 ports..."
#Create port #1 for VNF #2 and get its id
export VNF_2_port_1_id=$(neutron port-create $NFV_net_out_name \
 --tenant-id $NFV_tenant_id \
 --fixed-ip subnet-id=$NFV_subnet_out_name,ip_address=$VNF_2_ip_1 \
 |grep " id "|awk -F '|' '{print $3}'| tr -d ' ')
#Add this port to the environment variables for use at "destroy" time
echo  "export VNF_2_port_1_id=$VNF_2_port_1_id" >> $ENVIRONMENT_PATH
#Create port #2 for VNF #2 and get its id
export VNF_2_port_2_id=$(neutron port-create $NFV_net_in_name \
 --tenant-id $NFV_tenant_id \
 --fixed-ip subnet-id=$NFV_subnet_in_name,ip_address=$VNF_2_ip_2 \
 |grep " id "|awk -F '|' '{print $3}'| tr -d ' ')
#Add this port to the environment variables for use at "destroy" time
echo  "export VNF_2_port_2_id=$VNF_2_port_2_id" >> $ENVIRONMENT_PATH

#Authenticate as the NFV tenant to create VNFs in that project
export OS_TENANT_NAME=$NFV_tenant_name
export OS_PROJECT_NAME=$NFV_tenant_name
export OS_USERNAME=$NFV_tenant_name
export OS_PASSWORD=$NFV_tenant_name

#Create the VNF #1 using the port IDs
echo "Creating VNF #1 ..."
nova boot --flavor $VNF_flavor --image $VNF_1_image \
     --nic port-id=$VNF_1_port_1_id \
     --nic port-id=$VNF_1_port_2_id \
     $VNF_1_name
sleep 3

#CREATE VNF #2
echo "Creating VNF #2 ..."
#Create the VNF using the port IDs
nova boot --flavor $VNF_flavor --image $VNF_2_image \
     --nic port-id=$VNF_2_port_1_id \
     --nic port-id=$VNF_2_port_2_id \
     $VNF_2_name
sleep 3

#Create router-in
echo "Creating inside router..."
neutron router-create --tenant-id $NFV_tenant_id $rtr_in_name
sleep 1
#Add interfaces to router in corresponding networks
neutron router-interface-add $rtr_in_name $NFV_subnet_in_name
neutron router-interface-add $rtr_in_name $METRO_subnet_name
#Add default route to router in throught the vRouter VNF
neutron router-update $rtr_in_name --routes type=dict list=true destination=0.0.0.0/0,nexthop=$VNF_1_ip_2

#Enable Security Groups and rules so that the NFV tenant accepts adequate traffic. Initially all ports are open.
echo "Enabling firewall rules... "
#Get my "default" security group id
export default_secgroup_id=$(neutron security-group-list --tenant-id $NFV_tenant_id  |grep " default "|awk -F '|' '{print $2}'| tr -d ' ')
#Add my security group to the environment variables for use at "destroy" time
echo  "export default_secgroup_id=$default_secgroup_id" >> $ENVIRONMENT_PATH
#Enable ICMP ALL
neutron security-group-rule-create --tenant-id $NFV_tenant_id --direction ingress --protocol ICMP $default_secgroup_id
#Enable TCP ALL
neutron security-group-rule-create --tenant-id $NFV_tenant_id --direction ingress --protocol TCP --port-range-min 1 --port-range-max 65534  $default_secgroup_id
#Enable UDP ALL
neutron security-group-rule-create --tenant-id $NFV_tenant_id --direction ingress --protocol UDP --port-range-min 1 --port-range-max 65534  $default_secgroup_id

echo "Done! Environment Created."
