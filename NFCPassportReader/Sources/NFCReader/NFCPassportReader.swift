//
//  NFCPassportReader.swift
//  NFCPassportReader
//
//  Created by Davide Ceresola on 10/12/2020.
//

import Foundation
import CoreNFC
import ReactiveSwift

@available(iOS 14.0, *)
public protocol NFCPassportReaderDelegate: class {
    
    func readerDidBecomeActive()
    func reader(didFailedWith error: NFCError)
    func reader(didSuccededWith data: NFCData)
    
}

@available(iOS 14.0, *)
public class NFCPassportReader {
    
    private lazy var session: NFCSession = .init()
    
    public weak var delegate: NFCPassportReaderDelegate?
    
    private let mrzData: MRZData
    
    private lazy var disposable: SerialDisposable = .init()
    
    private var _nfcData: MutableProperty<NFCData> = MutableProperty(NFCData())
    
    public init(mrzData: MRZData) {
        
        self.mrzData = mrzData
        session.delegate = self
        
    }
    
    public func start() {
        
        session.start()
        
    }
    
    private func performFlow(tag: NFCTag, passportTag: NFCISO7816Tag) {
        
        let mrz = mrzData
        
        let progressBlock: ((Double) -> Void) = { [weak self] progress in
            self?.updateProgress(progress)
        }
        
        let flow = session.connectProducer(to: tag, passportTag: passportTag)
            .flatMap(.latest, NFCSelectCommand.performCommand(tag:)).map { ($0, mrz) }
            .progress(1.0 / 9.0, progressBlock: progressBlock)
            .flatMap(.latest, { NFCBacAuthCommand.performCommand(tag: $0, mrzData: $1) })
            .progress(2.0 / 9.0, progressBlock: progressBlock)
            .flatMap(.latest, { NFCMutualAuthCommand.performCommand(tag: $0.0, response: $0.1) })
            .progress(3.0 / 9.0, progressBlock: progressBlock)
            .flatMap(.latest, { NFCReadDGCommand.performCommand(tag: $0.0, dataGroup: .dg2, sessionKeys: $0.1) })
            .progress(4.0 / 9.0, progressBlock: progressBlock)
            .flatMap(.latest, { NFCExtractDataCommand.performCommand(tag: $0.0,
                                                                     sessionKeys: $0.1,
                                                                     maxLength: $0.2) })
            .progress(5.0 / 9.0, progressBlock: progressBlock)
            .flatMap(.latest, parseDG2(tag:data:sessionKeys:))
            .progress(6.0 / 9.0, progressBlock: progressBlock)
            .flatMap(.latest, { NFCReadDGCommand.performCommand(tag: $0.0, dataGroup: .dg11, sessionKeys: $0.1) })
            .progress(7.0 / 9.0, progressBlock: progressBlock)
            .flatMap(.latest, { NFCExtractDataCommand.performCommand(tag: $0.0, sessionKeys: $0.1, maxLength: $0.2) })
            .progress(8.0 / 9.0, progressBlock: progressBlock)
            .flatMap(.latest, parseDG11(tag:data:sessionKeys:))
            .progress(9.0 / 9.0, progressBlock: progressBlock)
        
        disposable.inner = flow
            .on(failed: { [weak self] error in
                self?.delegate?.reader(didFailedWith: error)
            })
            .on(completed: { [weak self] in
                guard let self = self else {
                    return
                }
                self.session.finish()
                self.delegate?.reader(didSuccededWith: self._nfcData.value)
            })
            .start()
        
    }
    
    private func parseDG2(tag: NFCISO7816Tag, data: Data, sessionKeys: SessionKeys) -> SignalProducer<(NFCISO7816Tag, SessionKeys), NFCError> {
        
        return SignalProducer { [weak self] observer, lifetime in
            
            guard let dg = try? DataGroup2(data.bytes) else {
                observer.send(error: .invalidCommand)
                return
            }
            
            self?._nfcData.modify { data in
                data = data.from(dg2: dg)
            }
            
            observer.send(value: (tag, sessionKeys))
            observer.sendCompleted()
            
        }
        
        
    }
    
    private func parseDG11(tag: NFCISO7816Tag, data: Data, sessionKeys: SessionKeys) -> SignalProducer<(NFCISO7816Tag, SessionKeys), NFCError> {
        
        return SignalProducer { [weak self] observer, lifetime in
            
            guard let dg = try? DataGroup11(data.bytes) else {
                observer.send(error: .invalidCommand)
                return
            }
            
            self?._nfcData.modify { data in
                data = data.from(dg11: dg)
            }
            
            observer.send(value: (tag, sessionKeys))
            observer.sendCompleted()
            
        }
        
    }
    
    private func updateProgress(_ progress: Double) {
        
        print("updating progress:", progress)
        let message: String
        
        if progress < 0.5 {
            message = "😐 25%\nScan in progress"
        } else if progress < 0.75 {
            message = "🙂 55%\nScan in progress"
        } else if progress < 1 {
            message = "😃 70%\nScan in progress"
        } else {
            message = "🤩 100%\nScan in progress"
        }
        
        session.message = message
        
    }
    
}

@available(iOS 14.0, *)
extension NFCPassportReader: NFCSessionDelegate {
    
    func session(didBecomeActive session: NFCTagReaderSession) {
        delegate?.readerDidBecomeActive()
    }
    
    func session(didFailedWith error: NFCError) {
        delegate?.reader(didFailedWith: error)
    }
    
    func session(didFoundTag tag: NFCTag, passportTag: NFCISO7816Tag) {
        performFlow(tag: tag, passportTag: passportTag)
    }
    
    
}

extension SignalProducer {
    
    func progress(_ progress: Double, progressBlock: ((Double) -> Void)? = nil) -> SignalProducer<Value, Error> {
        
        return self.on(completed: {
            progressBlock?(progress)
        })
    
    }
    
}
