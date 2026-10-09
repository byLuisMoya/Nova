import SwiftUI
import Charts

/// Una muestra (instante + valor) del histórico de una métrica.
struct HistoryPoint: Identifiable {
    let time: Date
    let value: Double
    /// Hueco del buffer circular (0..<capacidad). Swift Charts guarda en un
    /// diccionario interno cada `id` que ha visto; con un id por instante
    /// (`Date`) ese diccionario crece sin límite mientras la gráfica está
    /// visible. Con el hueco, el conjunto de ids queda acotado.
    let slot: Int
    var id: Int { slot }
}

// MARK: - Sparkline (mini-gráfica sin ejes)

/// Línea + área compacta para incrustar en filas (desplegable). El dominio Y se
/// ajusta a los datos con un pequeño margen para resaltar la tendencia.
struct Sparkline: View {
    let points: [HistoryPoint]
    let color: Color

    private var domain: ClosedRange<Double> {
        let values = points.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        if hi - lo < 1 { return (lo - 1)...(hi + 1) }
        let pad = (hi - lo) * 0.15
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        Chart(points) { p in
            AreaMark(x: .value("t", p.time), y: .value("v", p.value))
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(
                    colors: [color.opacity(0.25), color.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("t", p.time), y: .value("v", p.value))
                .interpolationMethod(.monotone)
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: domain)
        .chartPlotStyle { $0.clipped() }   // el trazo no se sale de su celda
        .chartLegend(.hidden)
    }
}

extension View {
    /// Da a una sparkline una altura fija y recorta su trazo a esa celda (sin
    /// recuadro visible), para que quede delimitada y no se pise con lo de al
    /// lado. El parámetro de color se mantiene por compatibilidad de llamada.
    func sparklineCard(_ tint: Color, height: CGFloat = 30) -> some View {
        self
            .frame(height: height)
            .clipped()
    }
}

// MARK: - Gráficas grandes (ventana detallada)

/// Historial de temperatura: una línea por componente, con leyenda y eje en la
/// unidad seleccionada (los valores se convierten desde °C al dibujar).
struct TempHistoryChart: View {
    let history: [SensorCategory: [HistoryPoint]]
    var unit: TemperatureUnit = .celsius

    private var categories: [SensorCategory] {
        SensorCategory.allCases.filter { !(history[$0] ?? []).isEmpty }
    }

    var body: some View {
        Chart {
            ForEach(categories, id: \.self) { cat in
                ForEach(history[cat] ?? []) { p in
                    LineMark(x: .value("Hora", p.time),
                             y: .value("Temperatura", unit.convert(p.value)),
                             series: .value("Componente", cat.rawValue))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(by: .value("Componente", cat.rawValue))
                }
            }
        }
        .chartForegroundStyleScale(domain: categories.map(\.rawValue),
                                   range: categories.map(\.accent))
        .chartYAxisLabel(unit.symbol)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
        .chartLegend(position: .bottom, spacing: 8)
    }
}

/// Historial de consumo: área apilada por bloque (la altura total es el consumo
/// total), con leyenda y eje W.
struct PowerHistoryChart: View {
    let history: [PowerComponent.Kind: [HistoryPoint]]

    private var kinds: [PowerComponent.Kind] {
        PowerComponent.Kind.allCases.filter { !(history[$0] ?? []).isEmpty }
    }

    var body: some View {
        Chart {
            ForEach(kinds, id: \.self) { kind in
                ForEach(history[kind] ?? []) { p in
                    AreaMark(x: .value("Hora", p.time),
                             y: .value("Potencia", p.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(by: .value("Bloque", kind.rawValue))
                }
            }
        }
        .chartForegroundStyleScale(domain: kinds.map(\.rawValue),
                                   range: kinds.map(\.accent))
        .chartYAxisLabel("W")
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
        .chartLegend(position: .bottom, spacing: 8)
    }
}
