import SwiftUI
import DivelogCore

struct FormulaListView: View {
    @EnvironmentObject var appState: AppState
    @State private var formulas: [Formula] = []
    @State private var showAddSheet = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(formulas, id: \.id) { formula in
                NavigationLink(destination: FormulaDetailView(formula: formula)) {
                    FormulaRowView(formula: formula)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        deleteFormula(formula)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Formulas")
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showAddSheet = true }) {
                    Image(systemName: "plus")
                }
            }
            #else
            ToolbarItem {
                Button(action: { showAddSheet = true }) {
                    Image(systemName: "plus")
                }
            }
            #endif
        }
        .sheet(isPresented: $showAddSheet, onDismiss: {
            Task { await loadFormulas() }
        }) {
            AddFormulaSheet()
        }
        .task {
            await loadFormulas()
        }
        .refreshable {
            await loadFormulas()
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func loadFormulas() async {
        do {
            formulas = try appState.diveService.listFormulas()
        } catch {
            errorMessage = "Failed to load formulas: \(error.localizedDescription)"
        }
    }

    private func deleteFormula(_ formula: Formula) {
        do {
            _ = try appState.diveService.deleteFormula(id: formula.id)
            formulas.removeAll { $0.id == formula.id }
        } catch {
            errorMessage = "Failed to delete formula: \(error.localizedDescription)"
        }
    }
}

struct FormulaRowView: View {
    let formula: Formula

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(formula.name)
                .font(.headline)
            Text(formula.expression)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct FormulaDetailView: View {
    @EnvironmentObject var appState: AppState
    let formula: Formula
    @State private var testResult: String = ""

    var body: some View {
        Form {
            Section("Formula") {
                LabeledContent("Name", value: formula.name)
                LabeledContent("Expression") {
                    Text(formula.expression)
                        .font(.system(.body, design: .monospaced))
                }
                if let desc = formula.description, !desc.isEmpty {
                    LabeledContent("Description", value: desc)
                }
            }

            Section("Test") {
                Button("Test with sample values") {
                    testFormula()
                }

                if !testResult.isEmpty {
                    Text(testResult)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(testResult.starts(with: "Error") ? .red : .green)
                }
            }

            Section("Available Functions") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(DivelogCompute.supportedFunctions(), id: \.name) { fn in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fn.name)
                                    .font(.system(.body, design: .monospaced))
                                    .fontWeight(.medium)
                                Text(fn.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(formula.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func testFormula() {
        let testVars: [String: Double] = [
            "max_depth_m": 30.0,
            "avg_depth_m": 18.0,
            "bottom_time_sec": 3000,
            "bottom_time_min": 50,
            "total_time_sec": 3600,
            "total_time_min": 60,
            "deco_time_sec": 600,
            "deco_time_min": 10,
            "cns_percent": 25,
            "otu": 30,
            "is_ccr": 1,
            "deco_required": 1,
            "min_temp_c": 16,
            "max_temp_c": 22,
            "avg_temp_c": 18,
        ]

        do {
            let result = try DivelogCompute.evaluateFormula(formula.expression, variables: testVars)
            testResult = "Result: \(result)"
        } catch {
            testResult = "Error: \(error)"
        }
    }
}

struct AddFormulaSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @State private var name = ""
    @State private var expression = ""
    @State private var formulaDescription = ""
    @State private var validationError: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                }

                Section("Expression") {
                    TextEditor(text: $expression)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 60)

                    if let error = validationError {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }

                Section {
                    TextField("Description", text: $formulaDescription, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Formula")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .frame(minWidth: 400, idealWidth: 500, minHeight: 350)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveFormula()
                    }
                    .disabled(name.isEmpty || expression.isEmpty || validationError != nil)
                }
            }
            .onChange(of: expression) { _, newValue in
                validateExpression(newValue)
            }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func validateExpression(_ expr: String) {
        if expr.isEmpty {
            validationError = nil
            return
        }
        validationError = DivelogCompute.validateFormula(expr)
    }

    private func saveFormula() {
        let formula = Formula(
            name: name,
            expression: expression,
            description: formulaDescription.isEmpty ? nil : formulaDescription
        )
        do {
            try appState.diveService.saveFormula(formula)
            dismiss()
        } catch {
            errorMessage = "Failed to save formula: \(error.localizedDescription)"
        }
    }
}
