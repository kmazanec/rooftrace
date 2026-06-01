import SwiftUI

struct JobRow: View {
    let job: JobSummary
    var isSkeleton = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(job.address)
                    .font(.RoofTrace.bodyMedium)
                    .foregroundStyle(Color.CC.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 8) {
                    StatusIndicator(status: job.status)
                    Text(job.createdAt, style: .relative)
                        .font(.RoofTrace.label)
                        .foregroundStyle(Color.CC.ink55)
                }
            }

            Spacer(minLength: 12)

            if let totalArea = job.totalAreaSqFt, job.ready {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(totalArea.formatted(.number.precision(.fractionLength(0))))
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.CC.ink)
                    Text("sq ft")
                        .font(.RoofTrace.label)
                        .foregroundStyle(Color.CC.ink55)
                }
                .accessibilityLabel("\(Int(totalArea.rounded())) square feet")
            }
        }
        .padding(16)
        .frame(minHeight: 72)
        .background(Color.CC.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.CC.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .redacted(reason: isSkeleton ? .placeholder : [])
        .accessibilityElement(children: .combine)
    }
}
