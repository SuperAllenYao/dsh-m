import Foundation

/// v6 实时步骤构建（纯函数，可单测）：把 ViewModel 的实时思考文本与工具准备列表
/// 映射成过程组内的 live 步骤（实时思考 1 条在前，工具准备行按 index 升序在后）。
/// 两个来源由 task-5（SessionJournal/ViewModel）提供，turn 结束结算后会被清空，
/// 因此这里返回空数组即表示「没有实时行」。
enum LiveProcessStepsBuilder {
    static func build(
        reasoningText: String,
        preparations: [LiveToolPreparation]
    ) -> [ProcessStep] {
        var steps: [ProcessStep] = []
        if !reasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            steps.append(
                ProcessStep(
                    id: "live-reasoning",
                    kind: .reasoning(reasoningText),
                    seq: 0,
                    isLive: true
                )
            )
        }
        for preparation in preparations.sorted(by: { $0.index < $1.index }) {
            steps.append(
                ProcessStep(
                    id: preparation.id,
                    kind: .preparing(name: preparation.name, args: preparation.arguments),
                    seq: 0,
                    isLive: true
                )
            )
        }
        return steps
    }
}

extension SessionViewModel {
 /// v6：本轮运行中的实时步骤（组内最后若干行）：实时思考在前、工具准备行按 index。
 /// 空串/空数组表示无实时行。
    var liveProcessSteps: [ProcessStep] {
        LiveProcessStepsBuilder.build(
            reasoningText: liveReasoningText,
            preparations: liveToolPreparations
        )
    }
}
