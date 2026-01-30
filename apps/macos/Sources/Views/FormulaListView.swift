import SwiftUI
import DivelogCore

struct FormulaListView: View {
    @EnvironmentObject var appState: AppState
    @State private var formulas: [Formula] = []
    @State private var selectedFormula: Formula?
    @State private var showAddSheet = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("\(formulas.count) formulas")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: { showAddSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                List(formulas, id: \.id, selection: $selectedFormula) { formula in
                    FormulaRowView(formula: formula)
                        .tag(formula)
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 300)

            if let formula = selectedFormula {
                FormulaDetailView(formula: formula)
            } else {
                VStack {
                    Image(systemName: "function")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Select a formula")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Create custom calculated fields")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Formulas")
        .sheet(isPresented: $showAddSheet) {
            AddFormulaSheet { formula in
                if let formula = formula {
                    formulas.append(formula)
                }
            }
        }
        .task {
            await loadFormulas()
        }
    }

    private func loadFormulas() async {
        do {
            formulas = try appState.diveService.listFormulas()
        } catch {
            print("Failed to load formulas: \(error)")
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
        .padding()
    }

    private func testFormula() {
        // Test with sample dive values
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
    @State private var description = ""
    @State private var validationError: String?

    let onSave: (Formula?) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Formula")
                .font(.title2)

            Form {
                TextField("Name", text: $name)

                VStack(alignment: .leading) {
                    Text("Expression")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: $expression)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 60)
                        .border(Color.gray.opacity(0.3))
                }

                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(2...4)

                if let error = validationError {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            .formStyle(.grouped)
            .onChange(of: expression) { _, newValue in
                validateExpression(newValue)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                    onSave(nil)
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    let formula = Formula(
                        name: name,
                        expression: expression,
                        description: description.isEmpty ? nil : description
                    )
                    do {
                        try appState.diveService.saveFormula(formula)
                        dismiss()
                        onSave(formula)
                    } catch {
                        print("Failed to save formula: \(error)")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || expression.isEmpty || validationError != nil)
            }
        }
        .padding()
        .frame(width: 500)
    }

    private func validateExpression(_ expr: String) {
        if expr.isEmpty {
            validationError = nil
            return
        }
        validationError = DivelogCompute.validateFormula(expr)
    }
}
