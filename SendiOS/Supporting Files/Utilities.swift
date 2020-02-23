//
//  Utilities.swift
//  SendiOS
//
//  Created by Annino De Petra on 21/02/2020.
//  Copyright © 2020 Annino De Petra. All rights reserved.
//

import Foundation

let udpPort: UInt16 = 9010
let tcpPort: UInt16 = 8010

enum Constant {
	static let serverDiscovery = "CHAT-SERVER-DISCOVERY"
	static let serverResponse = "CHAT-SERVER-RESPONSE-"
	static let nicknameRegex = "^/name: ([0-z]{4,})$"
	
	enum Message {
		static let searchingServer = "Searching a server nearby"
		static let presentMeAsServer = "Hello. I'm the server. Start spreading the news"
	}

	enum Interface {
		static let hotspot = "bridge"
		static let wlan = "en0"
	}
}

func htons(value: CUnsignedShort) -> CUnsignedShort {
    return (value << 8) + (value >> 8)
}

func ipAddress(from sockaddr_in: sockaddr_in) -> String {
	return String(cString: inet_ntoa(sockaddr_in.sin_addr))
}

func generateBroadcastSockAddrIn(source_address: String) -> sockaddr_in {
	var socket_broadcast_address = sockaddr_in()

	socket_broadcast_address.sin_family = sa_family_t(AF_INET)
	socket_broadcast_address.sin_addr.s_addr = inet_addr(source_address)
	socket_broadcast_address.sin_port = htons(value: udpPort)
	return socket_broadcast_address
}

func generateTCPSockAddrIn(server_address: String) -> sockaddr_in {
	var server_tcp_sock_addr = sockaddr_in()

	server_tcp_sock_addr.sin_family = sa_family_t(AF_INET)
	server_tcp_sock_addr.sin_addr.s_addr = inet_addr(server_address)
	server_tcp_sock_addr.sin_port = htons(value: tcpPort);
	return server_tcp_sock_addr
}

func generateReceiverSockAddrInTemplate(port: UInt16) -> sockaddr_in {
	var sock_addr = sockaddr_in()

	sock_addr.sin_family = sa_family_t(AF_INET)
	sock_addr.sin_addr.s_addr = INADDR_ANY
	sock_addr.sin_port = htons(value: port);
	return sock_addr
}