//
//  EffectivePowerApp.swift
//  EffectivePower
//
//  Created by Saagar Jha on 5/8/22.
//

import SwiftUI

@main
struct EffectivePowerApp: App {
    
    init() {
        // avoid crash on launch
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Saved Application State", isDirectory: true)
        do {
            try FileManager.default.removeItem(at: url)
            print("Saved Application State removed")
        } catch {
            print(error)
        }
    }
    
	var body: some Scene {
		DocumentGroup(newDocument: EffectivePowerDocument()) { file in
            ContentView(document: file.$document, specificApp: "", specificRootNode: "")
		}
	}
}
