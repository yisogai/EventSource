//
//  ViewController.swift
//  Example
//
//  Created by yisogai on 2017/11/01.
//  Copyright © 2017年 yisogai. All rights reserved.
//

import UIKit
import EventSource

class ViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {
    @IBOutlet weak var readyStateLabel: UILabel!
    @IBOutlet weak var reconnectButton: UIButton!
    @IBOutlet weak var tableView: UITableView!
    
    private var events: [MessageEvent] = []
    private var eventSource: EventSource?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        tableView.delegate = self
        tableView.dataSource = self
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        connect()
    }
    
    func connect() {
        eventSource?.close()
        
        let config = Configuration(headers: ["Authorization": "Bearer DUMMY_TOKEN"], lastEventId: "123", retryTime: 5)
        let source = EventSource(url: URL(string: "http://localhost:3000/chat/stream")!, configuration: config)
        eventSource = source
        showReadyState()
        
        source.onOpen { [weak self] in
            self?.showReadyState()
        }
        
        source.onError { [weak self] error in
            print(error.debugDescription)
            self?.showReadyState()
        }
        
        source.onMessage { [weak self] message in
            self?.events.insert(message, at: 0)
            self?.tableView.reloadData()
        }
        
        source.addEventListener("editMessage") { [weak self] event in
            self?.events.insert(event, at: 0)
            self?.tableView.reloadData()
        }
    }
    
    func showReadyState() {
        readyStateLabel.text = {
            if let source = eventSource {
                return "\(source.readyState)"
            } else {
                return "no source"
            }
        }()
        
        reconnectButton.isHidden = !(eventSource?.readyState == .closed)
    }
    
    // MARK: - UITableView
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return events.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let event = events[indexPath.row]
        
        cell.textLabel?.text = """
        type: \(event.type)
        lastEventId: \(event.lastEventId ?? "<nil>")
        data: \(event.data)
        """
        
        return cell
    }
    
    // MARK: - Handlers
    @IBAction func reconnectButtonTapped(_ sender: Any) {
        connect()
    }
}

