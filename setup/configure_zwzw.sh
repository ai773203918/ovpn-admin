  #!/usr/bin/env bash
  set -ex

  # 设置 EasyRSA 目录和服务器证书路径
  EASY_RSA_LOC="/etc/openvpn/easyrsa"
  SERVER_CERT="${EASY_RSA_LOC}/pki/issued/server.crt"

  # 设置 OpenVPN 服务器
  OVPN_SRV_NET=${OVPN_SERVER_NET:-172.16.100.0}  # VPN网络
  OVPN_SRV_MASK=${OVPN_SERVER_MASK:-255.255.255.0}  # VPN子网掩码
  # 设置 OpenVPN 协议(额外增加)
  OVPN_SRV_PROTOCOL=${OVPN_SERVER_PROTOCOL:-udp}

  # 进入 EasyRSA 目录
  cd $EASY_RSA_LOC

  # 检查是否存在服务器证书，如果不存在则生成新的证书
  if [ -e "$SERVER_CERT" ]; then
    echo "Found existing certs - reusing"
  else
    # 如果角色是 "slave"，等待从主节点同步初始数据
    if [ ${OVPN_ROLE:-"master"} = "slave" ]; then
      echo "等待来自主站的初始同步数据"
      while [ $(wget -q localhost/api/sync/last/try -O - | wc -m) -lt 1 ]
      do
        sleep 5
      done
    else
      # 生成新的服务器证书
      echo "生成新证书"
      easyrsa init-pki
      cp -R /usr/share/easy-rsa/* $EASY_RSA_LOC/pki
      echo "ca" | easyrsa build-ca nopass
      easyrsa build-server-full server nopass
      easyrsa gen-dh
      openvpn --genkey --secret ./pki/ta.key
    fi
  fi

  # 生成证书撤销列表 (CRL)
  easyrsa gen-crl

  # 配置 iptables 规则，用于网络地址转换 (NAT)
  iptables -t nat -D POSTROUTING -s ${OVPN_SRV_NET}/${OVPN_SRV_MASK} ! -d ${OVPN_SRV_NET}/${OVPN_SRV_MASK} -j MASQUERADE || true
  iptables -t nat -A POSTROUTING -s ${OVPN_SRV_NET}/${OVPN_SRV_MASK} ! -d ${OVPN_SRV_NET}/${OVPN_SRV_MASK} -j MASQUERADE

  # 创建 /dev/net/tun 设备
  mkdir -p /dev/net
  if [ ! -c /dev/net/tun ]; then
      mknod /dev/net/tun c 10 200
  fi

  # 复制 OpenVPN 配置文件
  cp -f /etc/openvpn/setup/openvpn.conf /etc/openvpn/openvpn.conf

  # 如果启用了密码验证，配置相关脚本和参数
  if [ ${OVPN_PASSWD_AUTH} = "true" ]; then
    mkdir -p /etc/openvpn/scripts/  # 创建存放脚本的目录
    cp -f /etc/openvpn/setup/auth.sh /etc/openvpn/scripts/auth.sh  # 复制密码验证脚本到指定目录
    chmod +x /etc/openvpn/scripts/auth.sh  # 赋予脚本执行权限
    echo "auth-user-pass-verify /etc/openvpn/scripts/auth.sh via-file" | tee -a /etc/openvpn/openvpn.conf  # 使用指定文件进行用户名和密码的验证
    echo "script-security 2" | tee -a /etc/openvpn/openvpn.conf  # 脚本的安全级别
    echo "verify-client-cert require" | tee -a /etc/openvpn/openvpn.conf  # 要求验证客户端证书
    # 判断是否配置了允许内部访问地址(额外增加,OVPN_LOCAL_NET 网络,OVPN_LOCAL_MASK 子网掩码)
    if [[ ${OVPN_LOCAL_NET} != "null" && ${OVPN_LOCAL_MASK} != "null" ]]; then
      echo 'push "route '${OVPN_LOCAL_NET}' '${OVPN_LOCAL_MASK}'"' | tee -a /etc/openvpn/openvpn.conf  # 添加允许访问的内部网络
    else
      echo '没有配置允许内部访问的地址'
    fi
    openvpn-user db-init --db.path=$EASY_RSA_LOC/pki/users.db  # 初始化用户数据库
  fi

  # 设置目录和文件权限
  [ -d $EASY_RSA_LOC/pki ] && chmod 755 $EASY_RSA_LOC/pki
  [ -f $EASY_RSA_LOC/pki/crl.pem ] && chmod 644 $EASY_RSA_LOC/pki/crl.pem

  # 创建 ccd 目录（用于存放客户端配置文件）
  mkdir -p /etc/openvpn/ccd

  # 启动 OpenVPN 服务器(已做修改,management 不做任何IP限制,通过容器仅部署容器间可访问)
  openvpn --config /etc/openvpn/openvpn.conf --client-config-dir /etc/openvpn/ccd --port 1194 --proto ${OVPN_SRV_PROTOCOL} --management 0.0.0.0 8989 --dev tun0 --server ${OVPN_SRV_NET} ${OVPN_SRV_MASK}
