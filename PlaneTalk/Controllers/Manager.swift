//
//  Manager.swift
//  SendiOS
//
//  Created by Annino De Petra on 20/02/2020.
//  Copyright © 2020 Annino De Petra. All rights reserved.
//

import Foundation

protocol ServerIPProvider: AnyObject {
	var serverIP: String? { get }
}

protocol GrantRoleDelegate: AnyObject {
	func deviceAsksServerPermissions(_ device: NetworkDevice)
}

enum DeviceType {
	case broadcastDevice(BroadcastDevice)
	case client(Client)
	case server(Server)
}

final class Manager: ServerIPProvider {
	// The instance of the current device
	private var currentDevice: DeviceType

	private var currentDeviceIP: String {
		switch currentDevice {
		case .client(let client):
			return client.ip
		case .server(let server):
			return server.ip
		case .broadcastDevice(let broadcastDevice):
			return broadcastDevice.ip
		}
	}

	private var broadcastDevice: BroadcastDevice? {
		guard case .broadcastDevice(let device) = currentDevice else {
			return nil
		}
		return device
	}

	private var client: Client? {
		guard case .client(let client) = currentDevice else {
			return nil
		}
		return client
	}

	private var server: Server? {
		guard case .server(let server) = currentDevice else {
			return nil
		}
		return server
	}

	var serverIP: String?

	var isServer: Bool {
		return server != nil
	}

	var isThereServer: Bool {
		return serverIP != nil
	}

	var presenter: MessagePresenter?

	private let messageFactory: MessageFactory

	init(broadcastDevice: BroadcastDevice) {
		self.currentDevice = .broadcastDevice(broadcastDevice)
		self.messageFactory = MessageFactory(device: broadcastDevice)
	}

	func allowBroadcastDeviceTransmissionReceptionUDPMessages() {
		// Open a socket, create a queue for handling the oncoming events, enable transmission of broadcast messages and find a server
		broadcastDevice?.enableReceptionAndTransmissionUDPMessages()
		// Find a server
		broadcastDevice?.findServer()
	}

	func send(_ message: String) {
		switch currentDevice {
		case .client(let client):
			client.sendToServerTCP(message)
		case .server(let server):
			server.sendServerText(message)
		case .broadcastDevice(_):
			break
		}
	}

	private func presentMessage(chatMessage: ChatMessage) {
		DispatchQueue.main.async { [weak self] in
			guard let _self = self else { return }
			_self.presenter?.show(chatMessage: chatMessage)
		}
	}
}

// MARK: - UDP UDPCommunicationDelegate
extension Manager: UDPCommunicationDelegate {
	var discoveryServerString: String {
		return messageFactory.discoveryMessage
	}

	// A new broadcast message has arrived
	func deviceDidReceiveBroadcastMessage(_ text: String, from sender: String) {
		// Generate Message
		let message = messageFactory.receivedUDPMessage(text, from: sender)
		// Since it's broadcast, you can receive your message back then skip it
		guard message.senderIP != currentDeviceIP else { return }

		if isServer {
			serverHasReceivedBroadcastMessage(message)
		} else {
			clientHasReceivedBroadcastMessage(message)
		}
	}

	// Server has received a client message
	private func serverHasReceivedBroadcastMessage(_ message: Message) {
		switch message.text {
		// If the server receives a discovery message it means that a new client wants to connect
		case messageFactory.discoveryMessage:
			// The server will reply sending back its IP
			let serverResponse = messageFactory.serverBroadcastAuthenticationResponse
			server?.sendBroadcastMessage(serverResponse)
			print("New client " + message.senderIP)
		default:
			assertionFailure("Server has received an unknown message \(message.text)")
			break
		}
	}

	// Client has received a server message
	private func clientHasReceivedBroadcastMessage(_ message: Message) {
		switch message.text {
		// If it's the server response to the discovery message
		case let string where string.contains(messageFactory.serverBroadcastAuthenticationResponseTemplate):
			guard !isThereServer else {
				assertionFailure("A server is already available @ \(serverIP!)")
				return
			}

			// Save the server IP
			let serverIP = message.senderIP
			self.serverIP = serverIP
			print("Found out a server @ " + message.senderIP)
			broadcastDevice?.clearKqueueEvents()

			let client = Client(
				ip: currentDeviceIP,
				serverIP: serverIP
			)

			currentDevice = .client(client)

			// Unbind from the UDP port and connect to the server via TCP
			client.clientTCPCommunicationDelegate = self
			client.startTCPconnectionToServer()
		default:
			assertionFailure("Client has received an unknown message \(message.text)")
			break
		}
	}
}

// MARK: - ServerTCPCommunicationDelegate
extension Manager: ServerTCPCommunicationDelegate {
	// Server wants to send his message
	func serverWantsToSendTCPText(_ text: String) -> MessageType {
		return messageFactory.generateServerMessage(from: text)
	}

	// Server wants to send a client message
	func serverDidReceiveClientTCPText(_ text: String, senderIP: String) -> MessageType {
		return messageFactory.generateClientMessage(from: text, senderIP: senderIP)
	}

	// Server did send his text
	func serverDidSendText(_ text: String) {
		let chatMessage = ChatMessage(text: text, sender: "Me", isMe: true)
		presentMessage(chatMessage: chatMessage)
	}

	// Server did a client text
	func serverDidSendClientText(_ text: String, clientIP: String) {
		let chatMessage = ChatMessage(text: text, sender: clientIP, isMe: false)
		presentMessage(chatMessage: chatMessage)
	}

	// Server did send an information text
	func serverDidSendInformationText(_ text: String) {
		let chatMessage = ChatMessage(text: text, sender: "Information", isMe: false)
		presentMessage(chatMessage: chatMessage)
	}
}

// MARK: - ClientTCPCommunicationDelegate
extension Manager: ClientTCPCommunicationDelegate {
	func clientDidReceiveTCPText(_ text: String) {
		let message = messageFactory.getTextAndServer(from: text)
		let chatMessage = ChatMessage(text: message.text, sender: message.senderIP, isMe: false)
		presentMessage(chatMessage: chatMessage)
	}

	func clientDidSendText(_ text: String) {
		let chatMessage = ChatMessage(text: text, sender: "Me", isMe: true)
		presentMessage(chatMessage: chatMessage)
	}
}

extension Manager: GrantRoleDelegate {
	func deviceAsksServerPermissions(_ device: NetworkDevice) {
		// When a client claims to become the server, check if there is already a device which is the current server
		guard
			!isThereServer,
			let device = broadcastDevice
		else {
			return
		}

		// Set up your IP as serverIP
		serverIP = device.ip

		print(Constant.Message.presentMeAsServer)

		// Create an instance of the Server class
		let server = Server(ip: device.ip,
							broadcastIP: device.broadcastIP,
							udp_broadcast_message_socket: device.udp_broadcast_message_socket,
							udp_reception_message_socket: device.udp_reception_message_socket
		)

		currentDevice = .server(server)
		server.serverTCPCommunicationDelegate = self
		server.udpCommunicationDelegate = device.udpCommunicationDelegate

		// Create a TCP socket to accept clients requests
		server.enableTCPCommunication()
	}
}
