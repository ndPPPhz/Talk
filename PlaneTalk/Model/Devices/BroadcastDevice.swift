//
//  BroadcastDevice.swift
//  PlaneTalk
//
//  Created by Annino De Petra on 14/03/2020.
//  Copyright © 2020 Annino De Petra. All rights reserved.
//

import Foundation

protocol BroadcastDevice: NetworkDevice {
	var broadcastIP: String { get }

	// The socket to communicate using the broadcast
	var udp_broadcast_message_socket: Int32 { get }
	// The socket used for receving broadcast messages
	var udp_reception_message_socket: Int32 { get }
	// The kqueue to handle both incoming broadcast messages and new connections
	var udpEventsKQueue: Int32 { get }

	var roleGrantDelegate: GrantRoleDelegate? { get }
	var udpCommunicationDelegate: UDPCommunicationDelegate? { get }

	func enableReceptionAndTransmissionUDPMessages()
	func clearKqueueEvents()

	func findServer()

	func sendBroadcastMessage(_ text: String)
}

extension BroadcastDevice {
	func enableReceptionAndTransmissionUDPMessages() {
		// Reception
		bindForUDPMessages()
		createBroadcastReceptionKqueue()

		// Transmission
		enableTransmissionToBroadcast()
	}

	private func bindForUDPMessages() {
		guard
			udp_reception_message_socket >= 0
		else {
			print("Error while creating fd")
			exit(-1)
		}

		let socket_binding_address = generateReceiverSockAddrInTemplate(port: udpPort)

		// Binding to a UDP Port
		let bindReturn = withUnsafePointer(to: socket_binding_address) { bindingAddressPtr -> Int32 in
			let rawBindingAddressPtr = UnsafeRawPointer(bindingAddressPtr).bindMemory(to: sockaddr.self, capacity: 1)
			let sockBindingAddressSize = UInt32(MemoryLayout<sockaddr_in>.stride)
			return bind(udp_reception_message_socket, rawBindingAddressPtr, sockBindingAddressSize)
		}

		guard bindReturn == 0 else {
			print("Couldn't bind the device to the port")
			exit(-1)
		}
	}

	private func createBroadcastReceptionKqueue() {
		if udpEventsKQueue == -1 {
			 print("Error while creating the broadcast kqueue")
			 exit(EXIT_FAILURE)
		 }

		// Create the kevent structure that sets up our kqueue to listen
        // for notifications
        var sockKevent = kevent(
            ident: UInt(udp_reception_message_socket),
            filter: Int16(EVFILT_READ),
            flags: UInt16(EV_ADD | EV_ENABLE),
            fflags: 0,
            data: 0,
            udata: nil
        )

        // This is where the kqueue is register with our
        // interest for the notifications described by
        // our kevent structure sockKevent
        kevent(udpEventsKQueue, &sockKevent, 1, nil, 0, nil)

		DispatchQueue.global(qos: .userInteractive).async { [weak self] in
			guard let _self = self else { return }
			var events: [kevent] = Array<kevent>(repeating: kevent(), count: 5)
            while true {
				// kevent is blocking. The thread will be blocked here until an event occurs
				let status = kevent(_self.udpEventsKQueue, nil, 0, &events, 1, nil)
				// When an event occurs
				if  status == 0 {
					 print("Timeout")
				 } else if status > 0 {
					for i in 0..<status {
						if (events[Int(i)].flags & UInt16(EV_EOF)) == EV_EOF {
							print("The socket (\(_self.udp_reception_message_socket)) has been closed.")
							return
						}

						withUnsafePointer(to: sockaddr_in()) { receiverAddressPtr in
							let stringBuffer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: 65536)
							let stringBufferRawPointer = UnsafeMutableRawPointer(stringBuffer.baseAddress)

							let rawReceiverAddressPtr = UnsafeRawPointer(receiverAddressPtr).bindMemory(to: sockaddr.self, capacity: 1)
							let sockAddressPtr: UnsafeMutablePointer<sockaddr> = UnsafeMutablePointer(mutating: rawReceiverAddressPtr)
							var sockBindingAddressSize = UInt32(MemoryLayout<sockaddr_in>.stride)
							let returnBytes = recvfrom(_self.udp_reception_message_socket, stringBufferRawPointer, 65536, 0, sockAddressPtr, &sockBindingAddressSize)

							let senderIP = ipAddress(from: receiverAddressPtr.pointee)

							guard
								let baseAddress = stringBuffer.baseAddress,
								returnBytes > 0
							else {
								print("Nothing to read from the buffer")
								return
							}

							let text = String(cString: UnsafePointer(baseAddress))
							DispatchQueue.main.async { [weak self] in
								guard let _self = self else { return }
								_self.udpCommunicationDelegate?.deviceDidReceiveBroadcastMessage(text, from: senderIP)
							}
						}
					}
				} else {
					break
				}
            }
        }
	}

	private func enableTransmissionToBroadcast() {
		guard
			udp_broadcast_message_socket >= 0
		else {
			print("Error while creating the fd")
			exit(-1)
		}

		var socket_broadcast_address = sockaddr_in()
		// set the socket
		socket_broadcast_address.sin_family = sa_family_t(AF_INET)
		socket_broadcast_address.sin_addr.s_addr = inet_addr(broadcastIP)
		socket_broadcast_address.sin_port = htons(value: 9010)

		let broadcast = 1;

		// SO_BROADCAST enables permission to transmit broadcast messages
		let optionReturn = withUnsafePointer(to: broadcast) { broadcastPrt in
			return setsockopt(udp_broadcast_message_socket, SOL_SOCKET, SO_BROADCAST, broadcastPrt, UInt32(MemoryLayout<Int>.size))
		}

		if optionReturn == -1 {
			print("Error while enable the transmission to broadcast")
			exit(-1)
		}
	}

	func sendBroadcastMessage(_ text: String) {
		guard udp_broadcast_message_socket > 0 else {
			print("Broadcast socket inactive")
			return
		}

		var socket_broadcast_address = generateBroadcastSockAddrIn(source_address: broadcastIP)

		text.withCString { cstr -> Void in
			let sentBytes: Int = withUnsafePointer(to: &socket_broadcast_address) { socketBroadcastAddressPtr in
				let broadcastMessageLength = Int(strlen(cstr))
				let socketBroadcastAddressRawPtr = UnsafeRawPointer(socketBroadcastAddressPtr).bindMemory(to: sockaddr.self, capacity: 1)
				// Send the message
				return sendto(udp_broadcast_message_socket, cstr, broadcastMessageLength, 0, socketBroadcastAddressRawPtr, UInt32(MemoryLayout<sockaddr_in>.stride))
			}

			guard sentBytes > 0 else {
				print("Nothing sent")
				return
			}
			print("Sent Broadcast message: \(text)")
		}
	}

	func findServer() {
		let serverDiscoveryString = udpCommunicationDelegate?.discoveryServerString

		serverDiscoveryString?.withCString { cString in
			let broadcastMessageLength = Int(strlen(cString))
			let socket_address_broadcast = generateBroadcastSockAddrIn(source_address: broadcastIP)

			withUnsafePointer(to: socket_address_broadcast) { broadcastAddressPtr in
				let rawBroadcastAddressPtr = UnsafeRawPointer(broadcastAddressPtr).bindMemory(to: sockaddr.self, capacity: 1)

				sendto(udp_broadcast_message_socket, cString, broadcastMessageLength, 0, rawBroadcastAddressPtr, UInt32(MemoryLayout<sockaddr_in>.stride))
				print(Constant.Message.searchingServer)

				DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
					guard let _self = self else { return }
					_self.roleGrantDelegate?.deviceAsksServerPermissions(_self)
				}
			}
		}
	}

	func clearKqueueEvents() {
		var sockKevent = kevent(
			ident: UInt(udp_reception_message_socket),
			filter: Int16(EVFILT_READ),
			flags: UInt16(EV_DELETE),
			fflags: 0,
			data: 0,
			udata: nil
		)

		if kevent(udpEventsKQueue, &sockKevent, 1, nil, 0, nil) == -1 {
			print("Kevent error")
		}
		// Even if there is no connection in UDP, close will free the fd from the kernel
		close(udpEventsKQueue)
	}
}
