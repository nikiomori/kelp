import Testing

@testable import BuiltinMachines

/// How long a machine's command has run: minutes and seconds, with the hours once there are any.
@Test func aMachinesRunTimeShowsHoursOnlyOnceThereAreAny() {
    #expect(MachineView.elapsed(41) == "0:41")
    #expect(MachineView.elapsed(3599) == "59:59")
    #expect(MachineView.elapsed(3600) == "1:00:00")
    #expect(MachineView.elapsed(4321) == "1:12:01")
}
