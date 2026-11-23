//
//  ModelPickerMenu.swift
//  OpenLearn
//
//  Created by Abdullah  on 23/11/2026.
//


import SwiftUI

struct ModelPickerMenu: View {
    @AppStorage("selectedModel") private var selectedModel: String = "auto"

    private var currentLabel: String {
        if selectedModel == GeminiService.autoID { return "Auto" }
        return GeminiService.models.first { $0.id == selectedModel }?.label ?? selectedModel
    }

    var body: some View {
        Menu {
            Picker("Model", selection: $selectedModel) {
                Text("Auto (switch if busy)").tag(GeminiService.autoID)
                ForEach(GeminiService.models, id: \.id) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(currentLabel, systemImage: "cpu")
        }
        .help("Choose which AI model to use")
    }
}