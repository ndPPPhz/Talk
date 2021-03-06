//
//  ClientCommunicationManager.swift
//  PlaneTalk
//
//  Created by Annino De Petra on 14/04/2021.
//  Copyright © 2021 Annino De Petra. All rights reserved.
//

import Foundation


protocol ClientCommunicationInterface {
	func startTCPconnectionToServer()
	func sendTextToServer(_ text: String)
	func closeCommunication()
}

final class ClientCommunicationManager: ClientCommunicationInterface {
	// The kqueue for all the tcp events
	private lazy var tcpEventQueue = kqueue()
	// TCP socket with the server
	private var client_tcp_socket_fd: Int32 = socket(AF_INET, SOCK_STREAM, 0)

	private var serverIP: String
	private let kQueueEventQueue: DispatchQueue
	private let propagationQueue: DispatchQueue

	weak var clientCommunicationDelegate: ClientCommunicationDelegate?
	weak var clientConnectionDelegate: ClientConnectionDelegate?

	init(
		serverIP: String,
		kQueueEventQueue: DispatchQueue = DispatchQueue(label: "com.ndPPPhz.PlaneTalk-clientKQueue", qos: .userInteractive),
		propagationQueue: DispatchQueue = .main
	) {
		self.kQueueEventQueue = kQueueEventQueue
		self.serverIP = serverIP
		self.propagationQueue = propagationQueue
	}

	func startTCPconnectionToServer() {
		if (client_tcp_socket_fd == -1) {
			print("TCP Socket creation failed");
			exit(-1);
		}

		// The struct containing the address of the server (for the client)
		let server_tcp_sock_addr = generateTCPSockAddrIn(server_address: serverIP)

		let connect_return = withUnsafePointer(to: server_tcp_sock_addr) { tcpSocketAddressPtr -> Int32 in
			let rawTCPSocketAddressPtr = UnsafeRawPointer(tcpSocketAddressPtr).bindMemory(to: sockaddr.self, capacity: 1)
			let size = UInt32(MemoryLayout<sockaddr>.stride)
			return connect(client_tcp_socket_fd, rawTCPSocketAddressPtr, size)
		}

		if connect_return == -1 {

			print("Connect to the server @\(serverIP) via TCP failed");
			exit(-1)
		}

		print("Connected via TCP to the Server")
		createTCPKQueue()
	}

	private func createTCPKQueue() {
		if tcpEventQueue == -1 {
			 print("Error creating kqueue")
			 exit(EXIT_FAILURE)
		 }

		// Create the kevent structure that sets up our kqueue to listen
		// for notifications
		var sockKevent = kevent(
			ident: UInt(client_tcp_socket_fd),
			filter: Int16(EVFILT_READ),
			flags: UInt16(EV_ADD | EV_ENABLE),
			fflags: 0,
			data: 0,
			udata: nil
		)

		// This is where the kqueue is register with our
		// interest for the notifications described by
		// our kevent structure sockKevent
		kevent(tcpEventQueue, &sockKevent, 1, nil, 0, nil)
		tcpMessagesWatchLoop()
	}

	private func tcpMessagesWatchLoop() {
		kQueueEventQueue.async { [weak self] in
			while true {
				guard let _self = self else { return }
				var events: [kevent] = Array<kevent>(repeating: kevent(), count: 5)
				let status = kevent(_self.tcpEventQueue, nil, 0, &events, 1, nil)
				_self.receivedTCPConnectionStatus(status, socketKQueue: _self.tcpEventQueue, events: events)
			}
		}
	}

	private func receivedTCPConnectionStatus(_ status: Int32, socketKQueue: Int32, events: [kevent]) {
		switch status {
		case 0:
			print("Timeout")
		case 1...:
			for i in 0..<status {
				let event = events[Int(i)]
				let fd = event.ident

				guard fd == client_tcp_socket_fd else {
					print("Message from an unknown socket")
					return
				}

				if (Int32(event.flags) & EV_EOF == EV_EOF) {
					var sockKevent = kevent(
						ident: UInt(fd),
						filter: Int16(EVFILT_READ),
						flags: UInt16(EV_DELETE),
						fflags: 0,
						data: 0,
						udata: nil
					)

					if kevent(tcpEventQueue, &sockKevent, 1, nil, 0, nil) == -1 {
						print("Kevent error")
					}

					print("Connection lost ...")
					propagationQueue.async { [weak self] in
						self?.clientConnectionDelegate?.clientDidLoseConnectionWithServer()
					}
					close(Int32(fd))
				} else {
					handleReceivedTCPMessage(socket: Int32(fd))
				}
			}
		default:
			print("Kqueue error: \(String(cString: strerror(errno)))")
			return
		}
	}

	// Client has received a message from the server
	private func handleReceivedTCPMessage(socket: Int32) {
		let receivedStringBuffer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: 65536)
		let receivedStringBufferRawPointer = UnsafeMutableRawPointer(receivedStringBuffer.baseAddress)

		let returnBytes = recv(socket, receivedStringBufferRawPointer, 65536, 0)

		guard
			let baseAddress = receivedStringBuffer.baseAddress,
			returnBytes > 0
		else {
			print("Nothing to read from the buffer")
			return
		}

		let string = String(cString: UnsafePointer(baseAddress))
		clientCommunicationDelegate?.clientDidReceiveMessage(string)
	}

	func sendTextToServer(_ text: String) {
		text.withCString { cstr -> Void in
			var server_tcp_sock_addr = generateTCPSockAddrIn(server_address: serverIP)

			let sentBytes: Int = withUnsafePointer(to: &server_tcp_sock_addr) {
				let tcpMessageLength = Int(strlen(cstr))
				let p = UnsafeRawPointer($0).bindMemory(to: sockaddr.self, capacity: 1)
				return sendto(client_tcp_socket_fd, cstr, tcpMessageLength, 0, p, UInt32(MemoryLayout<sockaddr_in>.stride))
			}

			guard sentBytes > 0 else {
				print("Error while sending")
				return
			}
			print("Sent to the server: \(text)")
			clientCommunicationDelegate?.clientDidSendMessage(text)
		}
	}

	func closeCommunication() {
		close(tcpEventQueue)
		close(client_tcp_socket_fd)
	}
}
