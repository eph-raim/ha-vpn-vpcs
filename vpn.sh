#!/bin/bash

# Configure HA VPN
HA_REGION=
HA_OTHER_LOCAL_IP=
HA_OTHER_LOCAL_ID=
HA_OTHER_LOCAL_RT_ID=
HA_OTHER_REMOTE_IP=
HA_REMOTE_CIDR=
HA_REMOTE_IP=

# Configure VPN client
LOCAL_CIDR=
REMOTE_CIDR=
REMOTE_EIP=

LOCAL_TUN_ID=0
LOCAL_TUN_IP=169.254.0.1
REMOTE_TUN_ID=0
REMOTE_TUN_IP=169.254.0.2
PING_TIMEOUT=3
CHECK_INTERVAL=5
WAIT_REBOOT=300

. /etc/profile.d/aws-apitools-common.sh

if [ x"$LOCAL_CIDR" == x"" -o x"$REMOTE_CIDR" == x"" -o x"$REMOTE_EIP" == x"" ]; then
    echo "If you want me to act like VPN client, you should set LOCAL_CIDR, REMOTE_CIDR and REMOTE_EIP."
    vpn_client=0
else
    vpn_client=1
fi

if [ x"$HA_OTHER_LOCAL_IP" == x"" -o x"$HA_OTHER_LOCAL_ID" == x"" -o x"$HA_OTHER_LOCAL_RT_ID" == x"" -o x"$HA_OTHER_REMOTE_IP" == x"" -o x"$HA_REGION" == x"" -o x"$HA_REMOTE_CIDR" == x"" -o x"$HA_REMOTE_IP" == x"" ]; then
    echo "If you want me to implement HA, you should set HA_OTHER_LOCAL_IP, HA_OTHER_LOCAL_ID, HA_OTHER_LOCAL_RT_ID, HA_OTHER_REMOTE_IP, HA_REGION, HA_REMOTE_CIDR and HA_REMOTE_IP."
    ha=0
else
    ha=1
    reboot=0
    take_over=0
    LOCAL_ID=$(/usr/bin/curl --silent http://169.254.169.254/latest/meta-data/instance-id)
    /opt/aws/bin/ec2-replace-route $HA_OTHER_LOCAL_RT_ID -r $HA_REMOTE_CIDR -i $HA_OTHER_LOCAL_ID --region=$HA_REGION
    if [ $? != 0 ]; then
        echo "Can't replace routing table!"
    fi
fi

while [ . ]
    do

    if [ $vpn_client == 1 ]; then
        # check ssh tunnel status
        /bin/ping -W $PING_TIMEOUT -c 1 $REMOTE_TUN_IP 2>&1 > /dev/null
        if [ $? != 0 ]; then
            echo $(date)
            echo "VPN Disconnected. Start to create VPN ..."
            echo '1' > /proc/sys/net/ipv4/ip_forward
            # create ssh tunnel
            ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=error $REMOTE_EIP "ps ax | grep 'sshd.*root@notty' | grep -v grep | awk '{print $1}' | xargs --no-run-if-empty -n 1 kill;"
            ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=error -f -w $LOCAL_TUN_ID:$REMOTE_TUN_ID $REMOTE_EIP "echo '1' > /proc/sys/net/ipv4/ip_forward;/sbin/ifconfig tun$REMOTE_TUN_ID up;/sbin/ifconfig tun$REMOTE_TUN_ID $REMOTE_TUN_IP netmask 255.255.255.0 pointopoint $LOCAL_TUN_IP;/sbin/route add -net $LOCAL_CIDR gw $REMOTE_TUN_IP;"
            sleep 5
            /sbin/ifconfig tun0 up
            /sbin/ifconfig tun0 $LOCAL_TUN_IP netmask 255.255.255.0 pointopoint $REMOTE_TUN_IP
            /sbin/route add -net $REMOTE_CIDR gw $LOCAL_TUN_IP
            # check connectivity
            /bin/ping -W $PING_TIMEOUT -c 1 $REMOTE_TUN_IP 2>&1 > /dev/null
            if [ $? == 0 ]; then
                echo "VPN has connected!"
            else
                echo "VPN can't connect!"
            fi
        fi
    fi

    if [ $ha == 1 ]; then
        # check ssh tunnel status
        /bin/ping -W $PING_TIMEOUT -c 1 $HA_REMOTE_IP 2>&1 > /dev/null
        if [ $? != 0 ];then
            connected=0
        else
            connected=1
        fi
        # check other ssh tunnel status
        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=error $HA_OTHER_LOCAL_IP "/bin/ping -W $PING_TIMEOUT -c 1 $HA_OTHER_REMOTE_IP 2>&1 > /dev/null"
        if [ $? != 0 ];then
            other_tunnel_connected=0
        else
            other_tunnel_connected=1
        fi
        # take over traffic if other ssh tunnel disconnect
        if [ $connected == 1 -a $other_tunnel_connected == 0 -a $take_over == 0 ]; then
            echo $(date)
            echo "Other ssh tunnel disconnect!"
            echo "Modify routing to VPN Instance!"
            /opt/aws/bin/ec2-replace-route $HA_OTHER_LOCAL_RT_ID -r $HA_REMOTE_CIDR -i $LOCAL_ID --region=$HA_REGION
            if [ $? != 0 ]; then
                echo "Can't replace routing table!"
                take_over=0
            else
                take_over=1
            fi

        fi
        # take back traffic if other ssh tunnel has connected
        if [ $other_tunnel_connected == 1 -a $take_over == 1 ]; then
            echo $(date)
            echo "Other ssh tunnel has connected!"
            echo "Modify routing to other VPN Instance!"
            /opt/aws/bin/ec2-replace-route $HA_OTHER_LOCAL_RT_ID -r $HA_REMOTE_CIDR -i $HA_OTHER_LOCAL_ID --region=$HA_REGION
            if [ $? != 0 ]; then
                echo "Can't replace routing table!"
                take_over=1
            else
                take_over=0
            fi
        fi
        # check other VPN instance status
        /bin/ping -W $PING_TIMEOUT -c 1 $HA_OTHER_LOCAL_IP 2>&1 > /dev/null
        if [ $? != 0 -a $reboot -lt $(date +%s -d "$WAIT_REBOOT seconds ago") ]; then
            echo $(date)
            echo "Other VPN instance disconnect!"
            echo "Reboot other VPN Instance!"
            /opt/aws/bin/ec2-reboot-instances $HA_OTHER_LOCAL_ID --region=$HA_REGION
            if [ $? != 0 ]; then
                /opt/aws/bin/ec2-start-instances $HA_OTHER_LOCAL_ID --region=$HA_REGION
                if [ $? != 0 ]; then
                    echo "Can't reboot other VPN instance!"
                else
                    reboot=$(date +%s)
                fi
            else
                reboot=$(date +%s)
            fi
        else
            reboot=0
        fi
    fi
    sleep $CHECK_INTERVAL
done
